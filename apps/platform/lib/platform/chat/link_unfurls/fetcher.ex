defmodule Platform.Chat.LinkUnfurls.Fetcher do
  @moduledoc """
  The one HTTP path link unfurls use (task 01a1a944 stage 2): it fetches an
  outside page, or a fixed oEmbed endpoint, for `Platform.Chat.LinkUnfurls`.

  ## Server-side request forgery

  A chat message chooses the URL, so this is an SSRF surface. The guard
  follows `Platform.Accounts.UserAvatarCache` and reuses its parts rather
  than inventing new ones:

    * `http` or `https` only, with a host and NO userinfo;
    * on EVERY hop, the first URL and each redirect `Location`, the host is
      resolved (A and AAAA, or a literal IP is parsed) and the hop is refused
      if ANY address is one federation refuses
      (`Platform.Federation.Peers.Client.forbidden_address?/1`: loopback,
      RFC 1918, CGNAT, link-local and cloud metadata, unique-local,
      multicast, reserved). The connection is then PINNED to the checked
      address through `Platform.Federation.Peers.PinnedAdapter`, with the
      name kept for Host, SNI and certificate checks, so a second DNS answer
      is never consulted. A string check on the hostname would not be
      enough: a public name can resolve to 10.0.0.1, and a public host can
      redirect to http://127.0.0.1;
    * redirects are followed by hand (`redirect: false`), at most
      three of them, each through the same check;
    * bounded: connect 3 s, one deadline for the whole fetch (5 s by
      default, every hop included), at most 1 MB of raw body, never
      decompressed, `retry: false`;
    * no cookie jar and no Cookie header; a generic User-Agent.

  A refusal is `{:error, {:refused, reason}}` and nothing further is
  fetched. Every other failure is `{:error, reason}`.

  ## Tests

  `config :platform, :link_unfurl_req_options` is merged into every request
  (test: `plug: {Req.Test, #{inspect(__MODULE__)}}`), and
  `config :platform, :link_unfurl_resolver` (a function or a static
  `%{host => [ip]}` map; test: `%{}`) replaces DNS, so no test reaches the
  network. `config :platform, :link_unfurl_timeout_ms` lowers the deadline.
  """

  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.PinnedAdapter

  @connect_timeout 3_000
  @timeout 5_000
  @max_body 1_048_576
  @max_redirects 3
  @user_agent "Mozilla/5.0 (compatible; LinkPreview/1.0)"
  @redirect_statuses [301, 302, 303, 307, 308]

  @html_types ["text/html", "application/xhtml+xml"]

  @type result ::
          {:ok, %{url: String.t(), body: binary(), content_type: String.t()}}
          | {:error, {:refused, atom()} | atom() | {:status, integer()}}

  @doc "The User-Agent every request sends."
  @spec user_agent() :: String.t()
  def user_agent, do: @user_agent

  @doc "The most redirects one fetch follows."
  @spec max_redirects() :: pos_integer()
  def max_redirects, do: @max_redirects

  @doc """
  GET `url` through the guard. `opts`:

    * `:accept`: the Accept header (default HTML);
    * `:types`: the content types accepted (default `text/html` and
      `application/xhtml+xml`).

  `{:ok, %{url: final_url, body: body, content_type: type}}` on a 200.
  """
  @spec get(String.t(), keyword()) :: result()
  def get(url, opts \\ []) when is_binary(url) do
    accept = Keyword.get(opts, :accept, "text/html,application/xhtml+xml")
    types = Keyword.get(opts, :types, @html_types)
    timeout = Application.get_env(:platform, :link_unfurl_timeout_ms, @timeout)

    # One deadline for the whole fetch, every hop included. The plug path
    # used in tests has no receive timeout of its own, so the deadline is
    # enforced here rather than left to the adapter.
    task =
      Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
        try do
          follow(url, accept, types, 0)
        rescue
          # Nothing here touches the Repo; the clause satisfies the
          # supervised-task audit and turns a stray sandbox error into a
          # plain failure.
          DBConnection.OwnershipError -> {:error, :transport}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :transport}
      nil -> {:error, :timeout}
    end
  end

  defp follow(url, accept, types, hops) do
    with {:ok, pinned} <- pin(url),
         {:ok, %Req.Response{} = resp} <- request(pinned, accept) do
      cond do
        resp.status in @redirect_statuses ->
          case location(resp, url) do
            nil -> {:error, {:status, resp.status}}
            _next when hops >= @max_redirects -> {:error, :too_many_redirects}
            next -> follow(next, accept, types, hops + 1)
          end

        resp.status == 200 ->
          with {:ok, type} <- content_type(resp, types), do: body(resp, url, type)

        true ->
          {:error, {:status, resp.status}}
      end
    end
  end

  defp body(%Req.Response{body: body}, url, type) when is_binary(body),
    do: {:ok, %{url: url, body: body, content_type: type}}

  defp body(_resp, _url, _type), do: {:error, :transport}

  defp location(resp, current) do
    case Req.Response.get_header(resp, "location") do
      [loc | _] when loc != "" ->
        current |> URI.merge(String.trim(loc)) |> URI.to_string()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp content_type(resp, types) do
    reported =
      resp
      |> Req.Response.get_header("content-type")
      |> List.first("")
      |> String.split(";")
      |> List.first()
      |> String.trim()
      |> String.downcase()

    if reported in types, do: {:ok, reported}, else: {:error, :unsupported_type}
  end

  defp request(%{url: target, hostname: hostname}, accept) do
    opts =
      [
        method: :get,
        url: target,
        headers: [{"accept", accept}, {"user-agent", @user_agent}],
        redirect: false,
        retry: false,
        # Never inflated: the byte cap counts the bytes actually received.
        raw: true,
        compressed: false,
        decode_body: false,
        adapter:
          PinnedAdapter.adapter(hostname,
            connect_timeout: @connect_timeout,
            receive_timeout: Application.get_env(:platform, :link_unfurl_timeout_ms, @timeout),
            max_body: @max_body
          ),
        # Only the `Req.Test` plug path streams through `:into`; PinnedAdapter
        # applies the same cap itself.
        into: &collect_capped/2
      ]
      |> Keyword.merge(Application.get_env(:platform, :link_unfurl_req_options, []))

    case Req.request(opts) do
      {:ok, %Req.Response{} = resp} ->
        if Req.Response.get_private(resp, :peer_too_large),
          do: {:error, :too_large},
          else: {:ok, resp}

      {:error, _} ->
        {:error, :transport}
    end
  rescue
    _ -> {:error, :transport}
  catch
    _, _ -> {:error, :transport}
  end

  defp collect_capped({:data, data}, {req, resp}) do
    body = if is_binary(resp.body), do: resp.body <> data, else: data

    if byte_size(body) > @max_body do
      {:halt,
       {req, resp |> Req.Response.put_private(:peer_too_large, true) |> Map.put(:body, "")}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  @doc false
  # http(s), a host, no userinfo; every resolved address public; the
  # request pinned to the address that was checked.
  @spec pin(String.t()) :: {:ok, %{url: String.t(), hostname: String.t()}} | {:error, term()}
  def pin(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when scheme not in ["http", "https"] ->
        {:error, {:refused, :scheme}}

      {:ok, %URI{userinfo: userinfo}} when not is_nil(userinfo) ->
        {:error, {:refused, :userinfo}}

      {:ok, %URI{host: host} = uri} when is_binary(host) and host != "" ->
        with {:ok, [ip | _] = addresses} <- resolve(host) do
          if Enum.any?(addresses, &Client.forbidden_address?/1) do
            {:error, {:refused, :forbidden_address}}
          else
            {:ok,
             %{
               url: URI.to_string(%URI{uri | host: ip |> :inet.ntoa() |> to_string()}),
               hostname: host
             }}
          end
        end

      # URI.new's own error carries part of the url; never pass that on.
      _ ->
        {:error, :malformed_url}
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
      case {literal, Application.get_env(:platform, :link_unfurl_resolver, &dns_resolve/1)} do
        {{:ok, ip}, _} -> {:ok, [ip]}
        {_, fun} when is_function(fun, 1) -> fun.(host)
        {_, %{} = static} -> {:ok, Map.get(static, host, [])}
      end

    case result do
      {:ok, [_ | _] = ips} -> {:ok, ips}
      _ -> {:error, :unresolvable}
    end
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
end
