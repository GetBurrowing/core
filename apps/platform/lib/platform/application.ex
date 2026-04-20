defmodule Platform.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Platform.Config.validate!()

    Platform.Audit.TelemetryHandler.attach()
    Platform.Vault.TelemetryHandler.attach()
    Platform.Chat.TelemetryHandler.attach()
    Platform.Memory.TelemetryHandler.attach()

    children =
      (maybe_chat_storage_boot_check() ++
         [
           Platform.Vault.Encryption,
           Platform.Repo,
           PlatformWeb.Telemetry,
           {DNSCluster, query: Application.get_env(:platform, :dns_cluster_query) || :ignore},
           {Phoenix.PubSub, name: Platform.PubSub},
           {Registry, keys: :unique, name: Platform.Agents.Registry},
           {Registry, keys: :unique, name: Platform.Execution.Registry},
           {Registry, keys: :unique, name: Platform.Orchestration.Registry},
           {Registry, keys: :unique, name: Platform.Chat.Registry},
           Platform.Agents.RuntimeSupervisor,
           Platform.Chat.CanvasSupervisor,
           # ContextBroker — must start after the agent registry/runtime tree
           Platform.Agents.ContextBroker,
           # Context plane supervisor — must start after PubSub
           Platform.Context.Supervisor,
           # Artifact substrate — task/run artifact records + publication history
           Platform.Artifacts.Store,
           # Execution plane — run supervisor (registry started above)
           Platform.Execution.RunSupervisor,
           # Orchestration — task router supervisor (registry started above)
           Platform.Orchestration.TaskRouterSupervisor,
           # Orchestration — declarative watcher: starts/stops routers based on task state
           Platform.Orchestration.TaskRouterWatcher,
           # Node context — ETS-backed space tracking for node canvas commands
           Platform.Federation.NodeContext,
           # Federation runtime presence tracker — before Endpoint so channels can use it
           Platform.Federation.RuntimePresence,
           # Dead letter buffer — in-process ring buffer for delivery failures
           Platform.Federation.DeadLetterBuffer,
           # Task supervisor for parallel agent dispatch (ADR 0027)
           {Task.Supervisor, name: Platform.TaskSupervisor},
           # Context plane — shared ETS context for federation (after Repo, before AttentionRouter)
           Platform.Chat.ContextPlane,
           # Active agent mutex — ETS-backed per-space agent tracking (ADR 0027)
           Platform.Chat.ActiveAgentStore,
           # Chat presence — must start after PubSub
           Platform.Chat.Presence,
           # Vault OAuth token refresh worker — must start after Repo and Vault.Encryption
           Platform.Vault.RefreshWorker,
           # Reap expired pending attachments (ADR 0039) — needs Repo
           Platform.Chat.AttachmentReaper,
           # Start to serve requests, typically the last entry
           PlatformWeb.Endpoint
         ])
      |> maybe_add_attention_router()
      |> maybe_add_node_client()
      |> maybe_add_system_event_scheduler()
      |> ensure_task_router_watcher_after_endpoint()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Platform.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Fail-closed: run unless explicitly skipped (dev/test). Prevents the
  # durability check from being silently bypassed in staging or any other
  # non-:prod-but-still-real environment.
  defp maybe_chat_storage_boot_check do
    if Application.get_env(:platform, :skip_attachment_storage_check, false) do
      []
    else
      [Platform.Chat.AttachmentStorage.BootCheck]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp maybe_add_attention_router(children) do
    if Application.get_env(:platform, :start_attention_router, true) do
      insert_at =
        Enum.find_index(children, fn child ->
          child == Platform.Orchestration.TaskRouterWatcher
        end) ||
          -1

      List.insert_at(children, insert_at, Platform.Chat.AttentionRouter)
    else
      children
    end
  end

  defp maybe_add_node_client(children) do
    if System.get_env("OPENCLAW_NODE_ENABLED") == "true" do
      children ++ [Platform.Federation.NodeClient]
    else
      children
    end
  end

  defp maybe_add_system_event_scheduler(children) do
    if Application.get_env(:platform, :start_system_event_scheduler, true) do
      idx = Enum.find_index(children, &(&1 == PlatformWeb.Endpoint)) || length(children)
      List.insert_at(children, idx, Platform.Agents.SystemEventScheduler)
    else
      children
    end
  end

  defp ensure_task_router_watcher_after_endpoint(children) do
    {watchers, others} =
      Enum.split_with(children, &(&1 == Platform.Orchestration.TaskRouterWatcher))

    case watchers do
      [] ->
        children

      [watcher] ->
        insert_at =
          (Enum.find_index(others, &(&1 == PlatformWeb.Endpoint)) || length(others) - 1) + 1

        List.insert_at(others, insert_at, watcher)
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    PlatformWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
