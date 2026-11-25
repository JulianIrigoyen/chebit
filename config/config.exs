# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :chebit,
  ecto_repos: [Chebit.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

# Configure the endpoint
config :chebit, ChebitWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ChebitWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Chebit.PubSub,
  live_view: [signing_salt: "zkVaNEuG"]

# Jobs run on Postgres. A job row commits in the same transaction as the change that needs it.
config :chebit, Oban,
  repo: Chebit.Repo,
  # One outbox job at a time: on one node, events leave in the order of their ids.
  queues: [outbox: 1, webhooks: 10, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Chebit.Payments.ExpiryWorker},
       {"7 * * * *", Chebit.Ledger.AuditWorker},
       {"17 * * * *", Chebit.Reconciliation.Worker}
     ]}
  ]

# A provider that is not in this map does not exist. Prod starts with no provider.
config :chebit, :providers, %{}

# Where the outbox publishes events.
config :chebit, :outbox_sink, Chebit.Outbox.PubSubSink

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
