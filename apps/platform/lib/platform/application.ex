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

    children =
      [
        Platform.Vault.Encryption,
        Platform.Repo,
        PlatformWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:platform, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Platform.PubSub},
        {Registry, keys: :unique, name: Platform.Agents.Registry},
        {Registry, keys: :unique, name: Platform.Execution.Registry},
        {Registry, keys: :unique, name: Platform.Orchestration.Registry},
        Platform.Agents.RuntimeSupervisor,
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
        # Orchestration — rehydrate active routers from DB after restart
        Platform.Orchestration.Rehydrator,
        # Node context — ETS-backed space tracking for node canvas commands
        Platform.Federation.NodeContext,
        # Federation runtime presence tracker — before Endpoint so channels can use it
        Platform.Federation.RuntimePresence,
        # Context plane — shared ETS context for federation (after Repo, before AttentionRouter)
        Platform.Chat.ContextPlane,
        # Chat presence — must start after PubSub
        Platform.Chat.Presence,
        # Vault OAuth token refresh worker — must start after Repo and Vault.Encryption
        Platform.Vault.RefreshWorker,
        # Start to serve requests, typically the last entry
        PlatformWeb.Endpoint
      ]
      |> maybe_add_attention_router()
      |> maybe_add_node_client()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Platform.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  defp maybe_add_attention_router(children) do
    if Application.get_env(:platform, :start_attention_router, true) do
      children ++ [Platform.Chat.AttentionRouter]
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

  @impl true
  def config_change(changed, _new, removed) do
    PlatformWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
