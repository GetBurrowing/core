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

    children = [
      Platform.Vault.Encryption,
      Platform.Repo,
      PlatformWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:platform, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Platform.PubSub},
      {Registry, keys: :unique, name: Platform.Agents.Registry},
      {Registry, keys: :unique, name: Platform.Execution.Registry},
      Platform.Agents.RuntimeSupervisor,
      # ContextBroker — must start after the agent registry/runtime tree
      Platform.Agents.ContextBroker,
      # Context plane supervisor — must start after PubSub
      Platform.Context.Supervisor,
      # Execution plane — run supervisor (registry started above)
      Platform.Execution.RunSupervisor,
      # Chat presence — must start after PubSub
      Platform.Chat.Presence,
      # AttentionRouter — must start after Repo and PubSub
      Platform.Chat.AttentionRouter,
      # Vault OAuth token refresh worker — must start after Repo and Vault.Encryption
      Platform.Vault.RefreshWorker,
      # Start to serve requests, typically the last entry
      PlatformWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Platform.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PlatformWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
