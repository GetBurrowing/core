defmodule Platform.Calendar.ExternalFetch do
  @moduledoc "HTTPS-only, DNS-pinned, bounded calendar fetches. Redirects are rejected."
  alias Platform.Federation.Peers.{Client, PinnedAdapter}
  @max_bytes 1_048_576
  def fetch(url) do
    with {:ok, %{url: target, hostname: hostname}} <- pin(url),
         {:ok, response} <-
           Req.request(
             Keyword.merge(
               [
                 method: :get,
                 url: target,
                 redirect: false,
                 retry: false,
                 raw: true,
                 compressed: false,
                 decode_body: false,
                 headers: [{"accept", "text/calendar"}],
                 adapter:
                   PinnedAdapter.adapter(hostname,
                     connect_timeout: 3000,
                     receive_timeout: 5000,
                     max_body: @max_bytes
                   ),
                 into: &collect/2
               ],
               Application.get_env(:platform, :calendar_subscription_req_options, [])
             )
           ) do
      cond do
        Req.Response.get_private(response, :peer_too_large) -> {:error, :too_large}
        response.status != 200 -> {:error, :http_status}
        not is_binary(response.body) -> {:error, :invalid_body}
        byte_size(response.body) > @max_bytes -> {:error, :too_large}
        true -> {:ok, response.body}
      end
    else
      _ -> {:error, :fetch_failed}
    end
  rescue
    _ -> {:error, :fetch_failed}
  end

  defp collect({:data, data}, {req, resp}) do
    body = if is_binary(resp.body), do: resp.body <> data, else: data

    if byte_size(body) > @max_bytes do
      {:halt,
       {req, resp |> Req.Response.put_private(:peer_too_large, true) |> Map.put(:body, "")}}
    else
      {:cont, {req, %{resp | body: body}}}
    end
  end

  def pin(source) do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil} = uri}
         when is_binary(host) and host != "" <- URI.new(source),
         {:ok, [ip | _] = addresses} <- resolve(host) do
      case Enum.find(addresses, &Client.forbidden_address?/1) do
        nil ->
          {:ok,
           %{
             url: URI.to_string(%URI{uri | host: ip |> :inet.ntoa() |> to_string()}),
             hostname: host
           }}

        _bad ->
          {:error, :forbidden_address}
      end
    else
      # URI.new's own error carries part of the url; never pass that on.
      {:error, :unresolvable} = error -> error
      _ -> {:error, :malformed_url}
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
      case {literal,
            Application.get_env(:platform, :calendar_subscription_resolver, &dns_resolve/1)} do
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
