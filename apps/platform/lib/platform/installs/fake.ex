defmodule Platform.Installs.Fake do
  @moduledoc """
  Dev stub mode for `Platform.Installs` (task 01a10315 stage 2), on with
  `BURROW_INSTALLS_FAKE=1` in dev only. Nothing here runs in prod: the
  process is started only when `config :platform, Platform.Installs, fake: true`
  (set by `config/runtime.exs` inside `if config_env() == :dev`).

  It is three things over one ETS table:

    * the state behind `PlatformWeb.Dev.FakeDigitalOcean` (droplets,
      firewalls, DNS records, per-call counts, injected failures);
    * a `Platform.Installs.Render`, `Platform.Installs.Probe` and
      `Platform.Installs.Bootstrap` that advance each step after
      `fake_delay_ms` (3 s) and return `https://auth.fake.invalid/lc/FAKECODE`;
    * the failure injector: `inject_failure("reserve" | "install" | "connect" | "final", times)`
      makes that step fail `times` times.

  A customer-domain install waits in `connect` until `resolve_dns(host)` is
  called (`POST /dev/fake-digitalocean/_dns`), as a real one waits for the
  customer's DNS change.
  """

  use GenServer

  @behaviour Platform.Installs.Render
  @behaviour Platform.Installs.Probe
  @behaviour Platform.Installs.Bootstrap

  @table :platform_installs_fake
  @steps ~w(reserve install connect final)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "The fake's steps that accept an injected failure."
  def steps, do: @steps

  @doc "Forget every droplet, firewall, record, count and injected failure."
  def reset, do: :ets.delete_all_objects(@table)

  # ---------------------------------------------------------------------------
  # Store
  # ---------------------------------------------------------------------------

  @doc false
  def put(key, value), do: :ets.insert(@table, {key, value})

  @doc false
  def delete(key), do: :ets.delete(@table, key)

  @doc false
  def all(kind), do: :ets.match_object(@table, {{kind, :_}, :_}) |> Enum.map(&elem(&1, 1))

  @doc false
  def next_id, do: :ets.update_counter(@table, :next_id, {2, 1}, {:next_id, 1000})

  @doc "Count one API call under `key` (e.g. `\"POST /v2/droplets\"`)."
  def count(key), do: :ets.update_counter(@table, {:calls, key}, {2, 1}, {{:calls, key}, 0})

  @doc "`%{\"METHOD /path\" => count}` of every API call so far."
  def calls do
    @table
    |> :ets.match_object({{:calls, :_}, :_})
    |> Map.new(fn {{:calls, key}, n} -> {key, n} end)
  end

  @doc "Make `step` fail its next `times` attempts."
  def inject_failure(step, times) when step in @steps and is_integer(times) and times > 0 do
    put({:fail, step}, times)
    :ok
  end

  @doc false
  def take_failure(step) do
    case :ets.lookup(@table, {:fail, step}) do
      [{_, n}] when n > 0 ->
        put({:fail, step}, n - 1)
        true

      _ ->
        false
    end
  end

  @doc "Make `host` resolve (a customer's DNS change landed)."
  def resolve_dns(host), do: put({:dns, host}, true)

  @doc "Milliseconds every fake wait lasts."
  def delay_ms,
    do: Keyword.get(Application.get_env(:platform, Platform.Installs, []), :fake_delay_ms, 3_000)

  @doc false
  def elapsed?(key) do
    now = System.monotonic_time(:millisecond)

    first =
      case :ets.lookup(@table, {:seen, key}) do
        [{_, at}] ->
          at

        [] ->
          put({:seen, key}, now)
          now
      end

    now - first >= delay_ms()
  end

  # ---------------------------------------------------------------------------
  # Render / Probe / Bootstrap
  # ---------------------------------------------------------------------------

  @impl Platform.Installs.Render
  def render(_install, _ssh_public_key) do
    {:ok,
     %{
       user_data: "#cloud-config\n# fake render (dev stub mode)\n",
       secrets: %{
         "STATIC_API_KEY" => "fake-static-api-key-dev-only",
         "OIDC_CLIENT_SECRET" => "fake-oidc-client-secret-dev-only"
       }
     }}
  end

  @impl Platform.Installs.Probe
  def http_up(install) do
    cond do
      take_failure("install") -> {:error, :injected_failure}
      elapsed?({install.id, "install"}) -> :ok
      true -> {:wait, :fake_delay}
    end
  end

  @impl Platform.Installs.Probe
  def dns_ready(install, hosts) do
    cond do
      take_failure("connect") ->
        {:error, :injected_failure}

      install.domain_mode == "customer" and
          not Enum.all?(hosts, &(:ets.lookup(@table, {:dns, &1}) != [])) ->
        {:wait, :dns}

      elapsed?({install.id, "connect"}) ->
        :ok

      true ->
        {:wait, :fake_delay}
    end
  end

  @impl Platform.Installs.Probe
  def https_health(install) do
    running = Enum.find_value(install.steps, "final", &(&1["state"] == "running" && &1["key"]))
    if elapsed?({install.id, running}), do: :ok, else: {:wait, :fake_delay}
  end

  @impl Platform.Installs.Bootstrap
  def admin_link(_install, _auth_host, _secrets) do
    if take_failure("final"),
      do: {:error, {:bootstrap_failed, "injected"}},
      else: {:ok, "https://auth.fake.invalid/lc/FAKECODE"}
  end
end
