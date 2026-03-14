defmodule Platform.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Platform.Config.validate!()
    Platform.Audit.TelemetryHandler.attach()

    children = [
      Platform.Repo,
      PlatformWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:platform, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Platform.PubSub},
      # Start a worker by calling: Platform.Worker.start_link(arg)
      # {Platform.Worker, arg},
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
