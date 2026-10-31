defmodule Platform.Installs.Runner do
  @moduledoc """
  The restartable step machine behind one install (task 01a10315 stage 2).

  Steps, in order (stage 3 labels them in business terms):

    * `reserve`: render, find-or-create the droplet BY TAG, the firewall, wait
      for `active` plus a public IPv4; in `ours` mode also the two A records;
    * `install`: Caddy answers `http://<ip>/` for the primary host;
    * `connect`: the primary and auth hosts resolve to the IP, then
      `https://<primary>/health` is 200 with a verified certificate;
    * `final`: `bootstrap-admin` (first admin plus core's OIDC client), then
      the health check again, then (task 01a18f76) memory and search must
      answer on three consecutive deep health polls at least a minute apart.

  Every step is safe to re-run. **A retry never creates a second droplet**:
  `reserve` lists droplets by the install's tag BEFORE any POST, and the tag
  is set at create time, so a crash between the POST and saving
  `droplet_id` finds the droplet on the next run.

  A run is a process under `Platform.TaskSupervisor`, registered by install
  id in `Platform.Installs.Registry` so one install never has two runs.
  Progress lives in the `installs` row, so `Platform.Installs.resume_all/0`
  restarts unfinished runs at boot. Each change broadcasts
  `{:install_updated, id}` on `"install:<id>"`. No secret is ever put in a
  step, an error, a log line or a broadcast.

  Knobs (`config :platform, Platform.Installs`): `poll_interval_ms` (10 s),
  `step_timeouts_ms` (a map by step key), `memory_poll_interval_ms` (60 s)
  and `memory_ok_required` (3).
  """

  require Logger

  alias Platform.Installs
  alias Platform.Installs.Bootstrap
  alias Platform.Installs.DigitalOcean
  alias Platform.Installs.Handover
  alias Platform.Installs.Install
  alias Platform.Installs.Probe
  alias Platform.Installs.Render

  @steps ~w(reserve install connect final)
  @default_timeouts %{
    "reserve" => :timer.minutes(15),
    "install" => :timer.minutes(30),
    # A customer's own domain waits here until their DNS change lands.
    "connect" => :timer.hours(48),
    "final" => :timer.minutes(15)
  }

  @doc "The step keys, in order."
  def steps, do: @steps

  @doc "A fresh step list, every step pending."
  def initial_steps do
    Enum.map(
      @steps,
      &%{
        "key" => &1,
        "state" => "pending",
        "started_at" => nil,
        "finished_at" => nil,
        "error" => nil
      }
    )
  end

  @doc "Start a run under `Platform.TaskSupervisor` (a no-op if one is running)."
  @spec start(String.t()) :: DynamicSupervisor.on_start_child()
  def start(install_id) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> supervised_run(install_id) end)
  end

  # A run spawned from an `async: true` test is outside the sandbox owner
  # chain (supervised_task_repo_audit_test.exs). Its row stays where it was;
  # resume_all/0 restarts it on the next boot.
  defp supervised_run(install_id) do
    run(install_id)
  rescue
    DBConnection.OwnershipError -> :stopped
  end

  @doc "The pid of the install's running run, or nil."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(install_id) do
    case Registry.lookup(Platform.Installs.Registry, install_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Kill the install's run, if any, and wait until it is gone."
  @spec stop(String.t()) :: :ok
  def stop(install_id) do
    case whereis(install_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          5_000 -> :ok
        end
    end
  end

  @doc """
  Run the install to `ready`, `failed` or a stop, in the calling process.
  Returns `:ready | :failed | :stopped | :already_running`.
  """
  @spec run(String.t()) :: :ready | :failed | :stopped | :already_running
  def run(install_id) do
    case Registry.register(Platform.Installs.Registry, install_id, nil) do
      {:ok, _} ->
        try do
          loop(install_id)
        after
          Registry.unregister(Platform.Installs.Registry, install_id)
        end

      {:error, {:already_registered, _}} ->
        :already_running
    end
  end

  defp loop(id) do
    install = Installs.get(id)

    cond do
      install == nil -> :stopped
      install.status in ~w(destroying destroyed) -> :stopped
      install.status in ~w(failed ready) -> String.to_atom(install.status)
      true -> next_step(install)
    end
  end

  defp next_step(install) do
    case Enum.find(install.steps, &(&1["state"] != "done")) do
      nil ->
        Installs.update!(install, %{status: "ready", ready_at: now()})
        :ready

      step ->
        run_step(install, step)
    end
  end

  defp run_step(install, step) do
    key = step["key"]
    started_at = step["started_at"] || iso(now())

    install =
      if step["state"] == "running" and install.status == "provisioning" do
        install
      else
        Installs.update!(install, %{
          status: "provisioning",
          steps: put_step(install.steps, key, %{"state" => "running", "started_at" => started_at})
        })
      end

    result =
      try do
        perform(key, install)
      rescue
        exception ->
          Logger.error(
            "[installs] step #{key} of #{install.id} raised #{inspect(exception.__struct__)}"
          )

          {:error, :crashed}
      end

    case normalize(result) do
      {:ok, attrs} ->
        install = Installs.get(install.id)

        Installs.update!(
          install,
          Map.put(
            attrs,
            :steps,
            put_step(install.steps, key, %{"state" => "done", "finished_at" => iso(now())})
          )
        )

        loop(install.id)

      {:wait, reason} ->
        if past_deadline?(key, started_at) do
          fail(install.id, key, deadline_reason(reason))
        else
          Process.sleep(poll_interval())
          loop(install.id)
        end

      {:error, reason} ->
        fail(install.id, key, reason)
    end
  end

  defp fail(id, key, reason) do
    install = Installs.get(id)

    Logger.warning("[installs] #{id} step #{key} failed: #{Installs.reason_code(reason)}")

    Installs.update!(install, %{
      status: "failed",
      steps:
        put_step(install.steps, key, %{
          "state" => "failed",
          "finished_at" => iso(now()),
          "error" => Installs.describe_error(key, reason)
        })
    })

    :failed
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp perform("reserve", install) do
    with {:ok, install} <- ensure_droplet(install),
         {:ok, firewall_id} <- DigitalOcean.ensure_firewall(install.id),
         {:ok, droplet} <- DigitalOcean.get_droplet(install.droplet_id) do
      install =
        if install.firewall_id == firewall_id,
          do: install,
          else: Installs.update!(install, %{firewall_id: firewall_id})

      ip = DigitalOcean.public_ipv4(droplet)

      if droplet["status"] == "active" and is_binary(ip) do
        with :ok <- ensure_dns(install, ip), do: {:ok, %{droplet_ip: ip}}
      else
        {:wait, :droplet_booting}
      end
    end
  end

  defp perform("install", install), do: Probe.impl().http_up(install)

  defp perform("connect", install) do
    probe = Probe.impl()

    with :ok <- probe.dns_ready(install, [install.primary_host, Installs.auth_host(install)]),
         :ok <- probe.https_health(install) do
      {:ok, %{}}
    end
  end

  defp perform("final", install) do
    with {:ok, sealed} <- Installs.unseal(install),
         :ok <- admin_ready(install, sealed) do
      memory_ready(install, Handover.fetch(sealed, "static_api_key"))
    end
  end

  # The droplet, looked up BY TAG before any POST (crash-safe), else created.
  defp ensure_droplet(%Install{droplet_id: id} = install) when is_integer(id), do: {:ok, install}

  defp ensure_droplet(install) do
    case DigitalOcean.find_droplets_by_tag(DigitalOcean.install_tag(install.id)) do
      {:ok, [droplet | _]} ->
        {:ok, Installs.update!(install, %{droplet_id: droplet["id"]})}

      {:ok, []} ->
        create_droplet(install)

      {:error, _} = error ->
        error
    end
  end

  defp create_droplet(install) do
    with {:ok, sealed} <- Installs.unseal(install),
         {:ok, rendered} <- Render.impl().render(install, install.ssh_public_key) do
      # Sealed BEFORE the POST: a droplet created from this render must never
      # exist without core holding its admin API key.
      sealed =
        sealed
        |> Handover.put("static_api_key", rendered.secrets["STATIC_API_KEY"])
        |> Handover.put("oidc_client_secret", rendered.secrets["OIDC_CLIENT_SECRET"])

      install = Installs.update!(install, %{handover_sealed: sealed})

      # Stage 6: root's key registered with the provider and named in the
      # create, or the provider expires root's password and key login stops at
      # "Password change required". Found by name first, so never registered twice.
      with {:ok, key_id} <- DigitalOcean.ensure_ssh_key(install.id, install.ssh_public_key),
           install = Installs.update!(install, %{ssh_key_id: key_id}),
           {:ok, droplet} <-
             DigitalOcean.create_droplet(%{
               install_id: install.id,
               name: install.slug,
               region: install.region,
               size: install.size,
               user_data: rendered.user_data,
               ssh_keys: [key_id]
             }) do
        {:ok, Installs.update!(install, %{droplet_id: droplet["id"]})}
      end
    end
  end

  defp ensure_dns(%Install{domain_mode: "ours"} = install, ip) do
    zone = Installs.ours_zone(install)

    with :ok <- DigitalOcean.ensure_a_record(zone, install.slug, ip) do
      DigitalOcean.ensure_a_record(zone, "auth." <> install.slug, ip)
    end
  end

  # A customer's own domain CNAMEs to <slug>.<zone> (Installs.dns_instructions/1),
  # so those targets point at the server too when a zone is configured.
  defp ensure_dns(install, ip) do
    case Installs.cname_zone() do
      nil ->
        :ok

      zone ->
        with :ok <- DigitalOcean.ensure_a_record(zone, install.slug, ip) do
          DigitalOcean.ensure_a_record(zone, "auth." <> install.slug, ip)
        end
    end
  end

  # `bootstrap-admin` then the health check, once: recorded on the step as
  # `"admin_ready"`, so the memory polls below do not re-run the bootstrap.
  defp admin_ready(install, sealed) do
    if final_step(install)["admin_ready"] do
      :ok
    else
      with {:ok, _link} <-
             Bootstrap.impl().admin_link(install, Installs.auth_host(install), %{
               "STATIC_API_KEY" => Handover.fetch(sealed, "static_api_key"),
               "OIDC_CLIENT_SECRET" => Handover.fetch(sealed, "oidc_client_secret")
             }),
           :ok <- Probe.impl().https_health(install) do
        save_final(install, %{"admin_ready" => true})
        :ok
      end
    end
  end

  # Memory and search work (task 01a18f76): `Probe.memory_ready/2` must answer
  # :ok on `memory_ok_required` (3) CONSECUTIVE polls at least
  # `memory_poll_interval_ms` (60 s) apart, so a crash-looping embeddings that
  # is up for a moment does not pass. Any other answer resets the count. The
  # progress (`memory_oks`, `memory_checked_at`) lives on the step, so a resumed
  # run continues it; the key is never stored there.
  defp memory_ready(install, static_api_key) do
    step = final_step(install)

    if checked_recently?(step) do
      {:wait, {:memory, :settling}}
    else
      result = Probe.impl().memory_ready(install, static_api_key)
      oks = if result == :ok, do: (step["memory_oks"] || 0) + 1, else: 0
      save_final(install, %{"memory_oks" => oks, "memory_checked_at" => iso(now())})

      cond do
        match?({:error, _}, result) -> result
        oks >= config(:memory_ok_required, 3) -> {:ok, %{}}
        result == :ok -> {:wait, {:memory, :settling}}
        true -> {:wait, {:memory, :unavailable}}
      end
    end
  end

  defp checked_recently?(%{"memory_checked_at" => at}) when is_binary(at) do
    {:ok, checked, _} = DateTime.from_iso8601(at)
    DateTime.diff(now(), checked, :millisecond) < config(:memory_poll_interval_ms, 60_000)
  end

  defp checked_recently?(_step), do: false

  defp final_step(install), do: Enum.find(install.steps, &(&1["key"] == "final")) || %{}

  defp save_final(install, changes) do
    install = Installs.get(install.id)
    Installs.update!(install, %{steps: put_step(install.steps, "final", changes)})
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The final step's memory wait names its own failure (describe_error/2).
  defp deadline_reason({:memory, _}), do: :memory_unavailable
  defp deadline_reason(_reason), do: :timeout

  defp normalize(:ok), do: {:ok, %{}}
  defp normalize(other), do: other

  defp put_step(steps, key, changes) do
    Enum.map(steps, fn
      %{"key" => ^key} = step -> Map.merge(step, changes)
      step -> step
    end)
  end

  defp past_deadline?(key, started_at) do
    {:ok, started, _} = DateTime.from_iso8601(started_at)
    DateTime.diff(now(), started, :millisecond) > Map.fetch!(timeouts(), key)
  end

  defp timeouts, do: Map.merge(@default_timeouts, Map.new(config(:step_timeouts_ms, %{})))
  defp poll_interval, do: config(:poll_interval_ms, :timer.seconds(10))

  defp config(key, default),
    do: Keyword.get(Application.get_env(:platform, Installs, []), key, default)

  defp now, do: DateTime.utc_now()
  defp iso(datetime), do: DateTime.to_iso8601(datetime)
end
