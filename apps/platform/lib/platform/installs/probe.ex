defmodule Platform.Installs.Probe do
  @moduledoc """
  The runner's checks of a booting install (task 01a10315 stage 2), behind a
  behaviour so tests and dev stub mode replace them
  (`config :platform, Platform.Installs, probe: Module`).

  Each callback answers `:ok` when the condition holds and `{:wait, reason}`
  while it does not yet; the runner polls until the step's deadline. An
  `{:error, reason}` fails the step at once (dev stub mode's injected
  failures).
  """

  alias Platform.Installs.Install

  @doc "Caddy answers `http://<ip>/` for `Host: <primary>` (a redirect to https counts)."
  @callback http_up(Install.t()) :: :ok | {:wait, term()} | {:error, term()}

  @doc "Each of `hosts` resolves to the install's IP."
  @callback dns_ready(Install.t(), [String.t()]) :: :ok | {:wait, term()} | {:error, term()}

  @doc "`https://<primary>/health` answers 200 with a verified certificate."
  @callback https_health(Install.t()) :: :ok | {:wait, term()} | {:error, term()}

  @doc "The configured implementation."
  def impl,
    do:
      Keyword.get(Application.get_env(:platform, Platform.Installs, []), :probe, __MODULE__.Live)
end

defmodule Platform.Installs.Probe.Live do
  @moduledoc "The real probes: plain HTTP to the IP, DNS, then HTTPS with verification."

  @behaviour Platform.Installs.Probe

  @impl true
  def http_up(install) do
    case Req.get("http://#{install.droplet_ip}/",
           headers: [{"host", install.primary_host}],
           redirect: false,
           retry: false,
           receive_timeout: 10_000,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..399 -> :ok
      {:ok, %Req.Response{status: status}} -> {:wait, {:http, status}}
      {:error, _} -> {:wait, :unreachable}
    end
  end

  @impl true
  def dns_ready(install, hosts) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(install.droplet_ip))

    case Enum.reject(hosts, &resolves_to?(&1, ip)) do
      [] -> :ok
      pending -> {:wait, {:dns, pending}}
    end
  end

  defp resolves_to?(host, ip) do
    case :inet.getaddrs(String.to_charlist(host), :inet) do
      {:ok, addrs} -> ip in addrs
      {:error, _} -> false
    end
  end

  @impl true
  def https_health(install) do
    case Req.get("https://#{install.primary_host}/health",
           retry: false,
           redirect: false,
           receive_timeout: 10_000,
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:wait, {:http, status}}
      {:error, _} -> {:wait, :unreachable}
    end
  end
end
