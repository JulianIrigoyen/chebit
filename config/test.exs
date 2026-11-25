import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :chebit, Chebit.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  port: 54330,
  database: "chebit_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :chebit, ChebitWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pHZKP9/d33DxwUeXpK+zUaxCWbcGxvPjLZ/MSCLHrNIjCvx/CGJhRlg8iKv5AeRJ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The simulated provider stands in for a real one. The secret signs its webhooks.
config :chebit, :providers, %{"simulated" => Chebit.Providers.Simulated}
config :chebit, Chebit.Providers.Simulated, webhook_secret: "test-simulated-webhook-secret"

# Tests run each job by hand, so a job never runs outside the test that made it.
config :chebit, Oban, testing: :manual

# The test sink sends each event to the process that registered for it.
config :chebit, :outbox_sink, Chebit.Outbox.TestSink

# The dashboard routes exist in test, so the LiveView tests can reach them. Prod sets no flag.
config :chebit, dev_routes: true
