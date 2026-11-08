defmodule Platform.Net.GuardedFetch do
  @moduledoc """
  Bounded, SSRF-guarded HTTP requests for URLs chosen outside the install.

  request/3 validates and resolves every URL (including redirects), refuses
  the whole resolution when any A or AAAA answer is forbidden, and pins the
  connection to an address that was checked. The original hostname is passed
  to Platform.Federation.Peers.PinnedAdapter for Host, SNI and certificate
  verification.

  The second argument is ordinary Req.request/1 options such as :headers,
  :method, or a Req.Test plug. Guard options are:

    * :schemes - allowed schemes as atoms or strings (default [:https]);
    * :resolver - a one-argument resolver or %{host => [ip_tuple]} map;
    * :max_body - maximum raw response bytes (default 1 MiB);
    * :max_redirects - redirects to follow (default 0);
    * :connect_timeout, :receive_timeout, and :timeout - milliseconds.

  Successful requests return the logical (un-pinned) final URL and the raw
  response fields. Errors are stable atoms/tuples and never include the URL.
  """

  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.PinnedAdapter

  @default_connect_timeout 5_000
  @default_receive_timeout 5_000
  @default_timeout 5_000
  @default_max_body 1_048_576
  @redirect_statuses [301, 302, 303, 307, 308]

  @type result ::
          {:ok,
           %{
             url: String.t(),
             status: non_neg_integer(),
             headers: map(),
             body: binary()
           }}
          | {:error,
             :malformed_url
             | :unresolvable
             | :too_large
             | :too_many_redirects
             | :timeout
             | :transport
             | {:refused, :scheme | :userinfo | :forbidden_address}}

  @doc """
  Requests url after validating, resolving, and pinning every hop.

  Security options (redirect, retry/decompression controls, adapter, and
  response collector) are applied after caller options and cannot be
  overridden by them. A :plug is intentionally retained for Req.Test.
  """
  @spec request(String.t(), keyword(), keyword()) :: result()
  def request(url, req_opts, guard_opts)
      when is_binary(url) and is_list(req_opts) and is_list(guard_opts) do
    timeout = positive_option(guard_opts, :timeout, @default_timeout)

    task =
      Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
        try do
          follow(url, req_opts, guard_opts, 0)
        rescue
          DBConnection.OwnershipError -> {:error, :transport}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :transport}
      nil -> {:error, :timeout}
    end
  rescue
    _ -> {:error, :transport}
  catch
    _, _ -> {:error, :transport}
  end

  def request(_url, _req_opts, _guard_opts), do: {:error, :malformed_url}

  defp follow(url, req_opts, guard_opts, redirects) do
    with {:ok, uri} <- parse(url, schemes(guard_opts)),
         {:ok, pinned_url, hostname} <- pin(uri, Keyword.get(guard_opts, :resolver)),
         {:ok, response} <- perform(pinned_url, hostname, req_opts, guard_opts) do
      if response.status in @redirect_statuses do
        follow_redirect(response, uri, req_opts, guard_opts, redirects)
      else
        success(response, uri)
      end
    end
  end

  defp follow_redirect(response, current_uri, req_opts, guard_opts, redirects) do
    max_redirects = non_negative_option(guard_opts, :max_redirects, 0)

    case redirect_location(response, current_uri) do
      {:ok, _next} when redirects >= max_redirects ->
        {:error, :too_many_redirects}

      {:ok, next} ->
        follow(next, req_opts, guard_opts, redirects + 1)

      :error ->
        success(response, current_uri)
    end
  end

  defp success(response, uri) do
    {:ok,
     %{
       url: URI.to_string(uri),
       status: response.status,
       headers: response.headers,
       body: response.body
     }}
  end

  defp redirect_location(response, current_uri) do
    case Req.Response.get_header(response, "location") do
      [location | _] when is_binary(location) and location != "" ->
        next = current_uri |> URI.merge(String.trim(location)) |> URI.to_string()
        {:ok, next}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse(url, allowed_schemes) do
    case URI.new(url) do
      {:ok, %URI{} = uri} ->
        cond do
          not is_binary(uri.host) or uri.host == "" -> {:error, :malformed_url}
          not is_nil(uri.userinfo) -> {:error, {:refused, :userinfo}}
          uri.scheme not in allowed_schemes -> {:error, {:refused, :scheme}}
          true -> {:ok, uri}
        end

      _ ->
        {:error, :malformed_url}
    end
  end

  defp pin(%URI{host: host} = uri, resolver) do
    with {:ok, addresses} <- resolve(host, resolver) do
      if Enum.any?(addresses, &Client.forbidden_address?/1) do
        {:error, {:refused, :forbidden_address}}
      else
        [ip | _] = addresses
        pinned = %URI{uri | host: ip |> :inet.ntoa() |> to_string()}
        {:ok, URI.to_string(pinned), host}
      end
    end
  end

  defp resolve(host, resolver) do
    literal =
      host
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.to_charlist()
      |> :inet.parse_strict_address()

    result =
      case {literal, resolver} do
        {{:ok, ip}, _} -> {:ok, [ip]}
        {_, fun} when is_function(fun, 1) -> safe_resolve(fun, host)
        {_, %{} = static} -> {:ok, Map.get(static, host, [])}
        {_, nil} -> dns_resolve(host)
        _ -> {:error, :invalid_resolver}
      end

    case result do
      {:ok, [_ | _] = addresses} -> {:ok, addresses}
      _ -> {:error, :unresolvable}
    end
  end

  defp safe_resolve(fun, host) do
    fun.(host)
  rescue
    _ -> {:error, :resolver}
  catch
    _, _ -> {:error, :resolver}
  end

  defp dns_resolve(host) do
    name = String.to_charlist(host)

    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(name, family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)

    {:ok, addresses}
  end

  defp perform(url, hostname, req_opts, guard_opts) do
    max_body = positive_option(guard_opts, :max_body, @default_max_body)
    connect_timeout = positive_option(guard_opts, :connect_timeout, @default_connect_timeout)
    receive_timeout = positive_option(guard_opts, :receive_timeout, @default_receive_timeout)

    forced = [
      redirect: false,
      retry: false,
      raw: true,
      compressed: false,
      decode_body: false,
      adapter:
        PinnedAdapter.adapter(hostname,
          connect_timeout: connect_timeout,
          receive_timeout: receive_timeout,
          max_body: max_body
        ),
      into: collector(max_body)
    ]

    opts =
      req_opts
      |> Keyword.put(:url, url)
      |> Keyword.put_new(:method, :get)
      |> Keyword.merge(forced)

    case Req.request(opts) do
      {:ok, %Req.Response{} = response} ->
        cond do
          Req.Response.get_private(response, :peer_too_large) -> {:error, :too_large}
          not is_binary(response.body) -> {:error, :transport}
          true -> {:ok, response}
        end

      {:error, _reason} ->
        {:error, :transport}
    end
  rescue
    _ -> {:error, :transport}
  catch
    _, _ -> {:error, :transport}
  end

  defp collector(max_body) do
    fn {:data, data}, {request, response} ->
      body = if is_binary(response.body), do: response.body <> data, else: data

      if byte_size(body) > max_body do
        {:halt,
         {request,
          response
          |> Req.Response.put_private(:peer_too_large, true)
          |> Map.put(:body, "")}}
      else
        {:cont, {request, %{response | body: body}}}
      end
    end
  end

  defp schemes(opts) do
    opts
    |> Keyword.get(:schemes, Keyword.get(opts, :allowed_schemes, [:https]))
    |> List.wrap()
    |> Enum.map(&to_string/1)
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end
end
