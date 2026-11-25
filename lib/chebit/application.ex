defmodule Chebit.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ChebitWeb.Telemetry,
      Chebit.Repo,
      {DNSCluster, query: Application.get_env(:chebit, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Chebit.PubSub},
      # Each connected dashboard process registers here. The page shows the count.
      {Registry, keys: :duplicate, name: ChebitWeb.DashboardRegistry},
      # Bulk payment runs from the dashboard (ChebitWeb.DashboardSimulation) run here.
      {Task.Supervisor, name: ChebitWeb.SimulationSupervisor},
      {Oban, Application.fetch_env!(:chebit, Oban)},
      # Start a worker by calling: Chebit.Worker.start_link(arg)
      # {Chebit.Worker, arg},
      # Start to serve requests, typically the last entry
      ChebitWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Chebit.Supervisor]
    Supervisor.start_link(children ++ provider_children(), opts)
  end

  # A provider module that keeps state runs under the supervisor. Only the simulated
  # provider does, and only where the config lists it.
  defp provider_children do
    providers = Application.fetch_env!(:chebit, :providers)

    if Chebit.Providers.Simulated in Map.values(providers),
      do: [Chebit.Providers.Simulated],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ChebitWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
