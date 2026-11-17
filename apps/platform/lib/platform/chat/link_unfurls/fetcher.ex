defmodule Platform.Chat.LinkUnfurls.Fetcher do
  @moduledoc """
  The one HTTP path link unfurls use (task 01a1a944 stage 2): it fetches an
  outside page, or a fixed oEmbed endpoint, for `Platform.Chat.LinkUnfurls`.

  Traversal is delegated to `Platform.Net.GuardedFetch`, which validates,
  resolves, pins, bounds, and revalidates every redirect hop. Link unfurls add
  their own request headers plus status and content-type adaptation.

  A refusal is `{:error, {:refused, reason}}` and nothing further is
  fetched. Every other failure is `{:error, reason}`.

  ## Tests

  `config :platform, :link_unfurl_req_options` is merged into every request
  (test: `plug: {Req.Test, #{inspect(__MODULE__)}}`), and
  `config :platform, :link_unfurl_resolver` (a function or a static
  `%{host => [ip]}` map; test: `%{}`) replaces DNS, so no test reaches the
  network. `config :platform, :link_unfurl_timeout_ms` lowers the one deadline
  shared by every hop.
  """

  alias Platform.Net.GuardedFetch

  @connect_timeout 3_000
  @timeout 5_000
  @max_body 1_048_576
  @max_redirects 3
  @user_agent "Mozilla/5.0 (compatible; LinkPreview/1.0)"

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

    req_opts =
      [
        method: :get,
        headers: [{"accept", accept}, {"user-agent", @user_agent}]
      ]
      |> Keyword.merge(Application.get_env(:platform, :link_unfurl_req_options, []))

    guard_opts = [
      schemes: [:http, :https],
      resolver: Application.get_env(:platform, :link_unfurl_resolver),
      max_body: @max_body,
      max_redirects: @max_redirects,
      connect_timeout: @connect_timeout,
      receive_timeout: timeout,
      timeout: timeout
    ]

    case GuardedFetch.request(url, req_opts, guard_opts) do
      {:ok, %{status: 200} = response} -> adapt(response, types)
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, :malformed_url} -> malformed_or_scheme(url)
      {:error, reason} -> {:error, reason}
    end
  end

  # GuardedFetch deliberately reports a missing host as malformed before it
  # checks the scheme. Link unfurls historically classify every non-http(s)
  # URI as a scheme refusal, including file:/// paths with no host.
  defp malformed_or_scheme(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when scheme not in ["http", "https"] ->
        {:error, {:refused, :scheme}}

      _ ->
        {:error, :malformed_url}
    end
  end

  defp adapt(%{url: url, body: body, headers: headers}, types) when is_binary(body) do
    with {:ok, type} <- content_type(headers, types) do
      {:ok, %{url: url, body: body, content_type: type}}
    end
  end

  defp adapt(_response, _types), do: {:error, :transport}

  defp content_type(headers, types) do
    reported =
      headers
      |> Map.get("content-type", [])
      |> List.first("")
      |> String.split(";")
      |> List.first()
      |> String.trim()
      |> String.downcase()

    if reported in types, do: {:ok, reported}, else: {:error, :unsupported_type}
  end
end
