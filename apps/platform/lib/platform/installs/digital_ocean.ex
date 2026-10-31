defmodule Platform.Installs.DigitalOcean do
  @moduledoc """
  DigitalOcean API v2 client for `Platform.Installs` (task 01a10315 stage 2).

  DigitalOcean only: the plan never substitutes another provider.

  ## Token

  Read on every call from the shared vault secret `digital-ocean-api-infra`
  (`Platform.Vault.get/2` with accessor `{:system, "installs-provisioner"}`)
  and refused unless it is a binary starting `dop_v1_`
  (`{:error, :do_token_unusable}`): a Vault decrypt path has been seen to
  answer `{:ok, :error}` (backlog task 01a13c96). The token never leaves this
  module and is never logged. `GET /v2/account` is 403 for this token and is
  never called.

  `config :platform, #{inspect(__MODULE__)}, token_source:` overrides where the
  token comes from: `{:vault, slug}` (default) or `{:static, token}` (tests
  and dev stub mode, so stub mode never reads the real token).

  ## Requests

  `base_url` (default `https://api.digitalocean.com`) and `req_options` come
  from the same config; `config/test.exs` sets
  `req_options: [plug: {Req.Test, #{inspect(__MODULE__)}}]` so no test reaches
  the network, and dev stub mode (`BURROW_INSTALLS_FAKE=1`) points it at
  `PlatformWeb.Dev.FakeDigitalOcean`.

  Every function returns `{:ok, value}` or `{:error, reason}` with
  `reason` one of `:do_token_unusable`, `:forbidden` (a 403: stop and report,
  never work around it), `:region_not_allowed`, `{:http, status}` or
  `{:transport, reason}`.

  ## Tags and names

  Droplets are tagged `burrow-install` and `burrow-install-<install id>`; the
  Cloud Firewall is named `burrow-install-<install id>` and targets that tag,
  so attaching it follows the tag and is idempotent. The account SSH key
  registered for the install's root key (stage 6) has the same name, so it is
  found again by name (never created twice) and removed by teardown.

  ## Sizes and regions (stage 6)

  `/v2/sizes` says which regions offer each size. `availability/0` caches
  `%{size => [region]}` (available sizes only) for an hour with the prices,
  so the admin form offers only regions that have the size, and a create is
  refused before any droplet POST. Measured 2026-10-30: `s-2vcpu-4gb` and
  `s-4vcpu-8gb` were offered in nyc1, sfo2 and sfo3 of our US list, NOT nyc3.
  """

  require Logger

  @default_base_url "https://api.digitalocean.com"
  @vault_slug "digital-ocean-api-infra"
  @accessor {:system, "installs-provisioner"}
  @image "ubuntu-24-04-x64"
  @regions ~w(nyc1 nyc2 nyc3 sfo2 sfo3 atl1 ric1)
  @sizes_cache_key {__MODULE__, :sizes}
  @sizes_ttl_ms :timer.hours(1)

  @doc "The US regions an install may be created in."
  @spec regions() :: [String.t()]
  def regions, do: @regions

  @doc "The droplet image every install boots."
  def image, do: @image

  @doc "The per-install tag (`burrow-install-<id>`)."
  @spec install_tag(String.t()) :: String.t()
  def install_tag(install_id), do: "burrow-install-#{install_id}"

  @doc "The Cloud Firewall name of an install (same as its tag)."
  def firewall_name(install_id), do: install_tag(install_id)

  # ---------------------------------------------------------------------------
  # Token
  # ---------------------------------------------------------------------------

  @doc """
  The API token, guarded. Anything but a binary starting `dop_v1_` is
  `{:error, :do_token_unusable}`; a Vault error is passed through.
  """
  @spec token() :: {:ok, String.t()} | {:error, term()}
  def token do
    case Keyword.get(config(), :token_source, {:vault, @vault_slug}) do
      {:static, value} -> guard_token({:ok, value})
      {:vault, slug} -> guard_token(Platform.Vault.get(slug, accessor: @accessor))
    end
  end

  @doc false
  @spec guard_token(term()) :: {:ok, String.t()} | {:error, term()}
  def guard_token({:ok, "dop_v1_" <> rest = token}) when byte_size(rest) > 0, do: {:ok, token}
  def guard_token({:ok, _not_a_token}), do: {:error, :do_token_unusable}
  def guard_token({:error, reason}), do: {:error, reason}
  def guard_token(_other), do: {:error, :do_token_unusable}

  # ---------------------------------------------------------------------------
  # Droplets
  # ---------------------------------------------------------------------------

  @doc "Droplets carrying `tag` (`GET /v2/droplets?tag_name=`)."
  @spec find_droplets_by_tag(String.t()) :: {:ok, [map()]} | {:error, term()}
  def find_droplets_by_tag(tag) do
    with {:ok, body} <- request(:get, "/v2/droplets", params: [tag_name: tag, per_page: 200]) do
      {:ok, Map.get(body, "droplets", [])}
    end
  end

  @doc """
  Create one droplet. `attrs`: `:install_id`, `:name`, `:region`, `:size`,
  `:user_data` and `:ssh_keys` (account key ids; stage 6). The image, tags,
  monitoring and ipv6 are fixed here.
  """
  @spec create_droplet(map()) :: {:ok, map()} | {:error, term()}
  def create_droplet(%{region: region} = attrs) do
    if region in @regions do
      body = %{
        name: attrs.name,
        region: region,
        size: attrs.size,
        image: @image,
        user_data: attrs.user_data,
        ssh_keys: Map.get(attrs, :ssh_keys, []),
        tags: ["burrow-install", install_tag(attrs.install_id)],
        monitoring: true,
        ipv6: false
      }

      with {:ok, resp} <- request(:post, "/v2/droplets", json: body) do
        {:ok, Map.fetch!(resp, "droplet")}
      end
    else
      {:error, :region_not_allowed}
    end
  end

  @doc "One droplet by id."
  @spec get_droplet(integer()) :: {:ok, map()} | {:error, term()}
  def get_droplet(id) do
    with {:ok, body} <- request(:get, "/v2/droplets/#{id}") do
      {:ok, Map.fetch!(body, "droplet")}
    end
  end

  @doc "The droplet's public IPv4 address, or nil while it has none."
  @spec public_ipv4(map()) :: String.t() | nil
  def public_ipv4(droplet) do
    droplet
    |> get_in(["networks", "v4"])
    |> List.wrap()
    |> Enum.find_value(fn net -> net["type"] == "public" && net["ip_address"] end)
  end

  @doc "Reboot one droplet (`POST /v2/droplets/:id/actions`, type `reboot`)."
  @spec reboot_droplet(integer()) :: :ok | {:error, term()}
  def reboot_droplet(id) do
    with {:ok, _} <- request(:post, "/v2/droplets/#{id}/actions", json: %{type: "reboot"}),
         do: :ok
  end

  @doc "Delete every droplet carrying `tag` (`DELETE /v2/droplets?tag_name=`)."
  @spec delete_droplets_by_tag(String.t()) :: :ok | {:error, term()}
  def delete_droplets_by_tag(tag) do
    with {:ok, _} <- request(:delete, "/v2/droplets", params: [tag_name: tag]), do: :ok
  end

  # ---------------------------------------------------------------------------
  # Account SSH key (stage 6)
  # ---------------------------------------------------------------------------

  @doc "The name of the install's account SSH key (same as its tag)."
  def ssh_key_name(install_id), do: install_tag(install_id)

  @doc """
  Find the install's account SSH key by name, or register `public_key` under
  it (`POST /v2/account/keys`). Returns its id. Passing that id in the
  droplet create is what keeps the provider from expiring root's password.
  """
  @spec ensure_ssh_key(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def ensure_ssh_key(install_id, public_key) do
    with {:ok, nil} <- find_ssh_key(install_id),
         {:ok, %{"ssh_key" => %{"id" => id}}} <-
           request(:post, "/v2/account/keys",
             json: %{name: ssh_key_name(install_id), public_key: public_key}
           ) do
      {:ok, id}
    else
      {:ok, %{"id" => id}} -> {:ok, id}
      {:error, _} = error -> error
      {:ok, _unexpected} -> {:error, :unexpected_response}
    end
  end

  @doc "Delete the install's account SSH key(s), by name. `:ok` when there is none."
  @spec delete_ssh_key(String.t()) :: :ok | {:error, term()}
  def delete_ssh_key(install_id) do
    name = ssh_key_name(install_id)

    with {:ok, body} <- request(:get, "/v2/account/keys", params: [per_page: 200]) do
      body
      |> Map.get("ssh_keys", [])
      |> Enum.filter(&(&1["name"] == name))
      |> Enum.reduce_while(:ok, fn %{"id" => id}, :ok ->
        case request(:delete, "/v2/account/keys/#{id}") do
          {:ok, _} -> {:cont, :ok}
          {:error, {:http, 404}} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp find_ssh_key(install_id) do
    name = ssh_key_name(install_id)

    with {:ok, body} <- request(:get, "/v2/account/keys", params: [per_page: 200]) do
      {:ok, Enum.find(Map.get(body, "ssh_keys", []), &(&1["name"] == name))}
    end
  end

  # ---------------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------------

  @doc """
  Find the install's firewall by name, or create it: inbound tcp 22/80/443
  from anywhere (IPv4 and IPv6), outbound everything, targeting the install
  tag. Returns its id.
  """
  @spec ensure_firewall(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_firewall(install_id) do
    with {:ok, nil} <- find_firewall(install_id),
         {:ok, %{"firewall" => fw}} <-
           request(:post, "/v2/firewalls", json: firewall_body(install_id)) do
      {:ok, fw["id"]}
    else
      {:ok, %{"id" => id}} -> {:ok, id}
      {:error, _} = error -> error
      {:ok, _unexpected} -> {:error, :unexpected_response}
    end
  end

  @doc "Delete the install's firewall if it exists."
  @spec delete_firewall(String.t()) :: :ok | {:error, term()}
  def delete_firewall(install_id) do
    case find_firewall(install_id) do
      {:ok, nil} ->
        :ok

      {:ok, %{"id" => id}} ->
        with {:ok, _} <- request(:delete, "/v2/firewalls/#{id}"), do: :ok

      {:error, _} = error ->
        error
    end
  end

  defp find_firewall(install_id) do
    name = firewall_name(install_id)

    with {:ok, body} <- request(:get, "/v2/firewalls", params: [per_page: 200]) do
      {:ok, Enum.find(Map.get(body, "firewalls", []), &(&1["name"] == name))}
    end
  end

  defp firewall_body(install_id) do
    anywhere = %{addresses: ["0.0.0.0/0", "::/0"]}

    %{
      name: firewall_name(install_id),
      inbound_rules:
        for(port <- ["22", "80", "443"], do: %{protocol: "tcp", ports: port, sources: anywhere}),
      outbound_rules:
        for(
          protocol <- ["tcp", "udp"],
          do: %{protocol: protocol, ports: "all", destinations: anywhere}
        ) ++ [%{protocol: "icmp", destinations: anywhere}],
      tags: [install_tag(install_id)]
    }
  end

  # ---------------------------------------------------------------------------
  # DNS
  # ---------------------------------------------------------------------------

  @doc "The DO-managed domains (`GET /v2/domains`, read-only)."
  @spec list_domains() :: {:ok, [map()]} | {:error, term()}
  def list_domains do
    with {:ok, body} <- request(:get, "/v2/domains", params: [per_page: 200]) do
      {:ok, Map.get(body, "domains", [])}
    end
  end

  @doc """
  Point the A record `name` (relative to `zone`, e.g. `acme` or `auth.acme`)
  at `ip`: create it, update it when it points elsewhere, or leave it.
  """
  @spec ensure_a_record(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_a_record(zone, name, ip) do
    case find_records(zone, name) do
      {:ok, []} ->
        body = %{type: "A", name: name, data: ip, ttl: 300}
        with {:ok, _} <- request(:post, "/v2/domains/#{zone}/records", json: body), do: :ok

      {:ok, [%{"data" => ^ip} | _]} ->
        :ok

      {:ok, [%{"id" => id} | _]} ->
        with {:ok, _} <-
               request(:put, "/v2/domains/#{zone}/records/#{id}", json: %{data: ip, ttl: 300}),
             do: :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Delete every A record named in `names` (relative to `zone`)."
  @spec delete_records(String.t(), [String.t()]) :: :ok | {:error, term()}
  def delete_records(zone, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      with {:ok, records} <- find_records(zone, name),
           :ok <- delete_each(zone, records) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp delete_each(zone, records) do
    Enum.reduce_while(records, :ok, fn %{"id" => id}, :ok ->
      case request(:delete, "/v2/domains/#{zone}/records/#{id}") do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp find_records(zone, name) do
    fqdn = "#{name}.#{zone}"

    with {:ok, body} <-
           request(:get, "/v2/domains/#{zone}/records", params: [type: "A", name: fqdn]) do
      {:ok, Map.get(body, "domain_records", [])}
    end
  end

  # ---------------------------------------------------------------------------
  # Sizes
  # ---------------------------------------------------------------------------

  @doc """
  `%{slug => price_monthly}` for every size, cached per node for an hour.
  """
  @spec sizes() :: {:ok, %{String.t() => number()}} | {:error, term()}
  def sizes do
    with {:ok, info} <- size_info(), do: {:ok, Map.new(info, fn {s, i} -> {s, i.price} end)}
  end

  @doc """
  `%{slug => [region]}`: the regions of OUR list (`regions/0`) where each
  AVAILABLE size can be created right now (stage 6). Same cache as `sizes/0`.
  """
  @spec availability() :: {:ok, %{String.t() => [String.t()] | nil}} | {:error, term()}
  def availability do
    with {:ok, info} <- size_info(), do: {:ok, Map.new(info, fn {s, i} -> {s, i.regions} end)}
  end

  defp size_info do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@sizes_cache_key, nil) do
      {at, info} when now - at < @sizes_ttl_ms ->
        {:ok, info}

      _ ->
        with {:ok, body} <- request(:get, "/v2/sizes", params: [per_page: 200]) do
          info = Map.new(Map.get(body, "sizes", []), &{&1["slug"], size_entry(&1)})
          :persistent_term.put(@sizes_cache_key, {now, info})
          {:ok, info}
        end
    end
  end

  # `regions: nil` when the provider did not say (unknown, so nothing is
  # filtered); `[]` when the size is not available anywhere.
  defp size_entry(size) do
    offered =
      cond do
        size["available"] == false -> []
        is_list(size["regions"]) -> Enum.filter(@regions, &(&1 in size["regions"]))
        true -> nil
      end

    %{price: size["price_monthly"], regions: offered}
  end

  @doc false
  def clear_sizes_cache, do: :persistent_term.erase(@sizes_cache_key)

  # ---------------------------------------------------------------------------
  # Transport
  # ---------------------------------------------------------------------------

  defp request(method, path, opts \\ []) do
    with {:ok, token} <- token() do
      req_opts =
        [
          method: method,
          base_url: Keyword.get(config(), :base_url, @default_base_url),
          url: path,
          auth: {:bearer, token},
          retry: false,
          receive_timeout: 30_000
        ]
        |> Keyword.merge(opts)
        |> Keyword.merge(Keyword.get(config(), :req_options, []))

      case Req.request(req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, if(is_map(body), do: body, else: %{})}

        {:ok, %Req.Response{status: 403}} ->
          Logger.warning("[installs] DigitalOcean refused #{method} #{path} with 403")
          {:error, :forbidden}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:http, status}}

        {:error, exception} ->
          {:error, {:transport, Exception.message(exception)}}
      end
    end
  end

  defp config, do: Application.get_env(:platform, __MODULE__, [])
end
