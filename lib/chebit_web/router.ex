defmodule ChebitWeb.Router do
  use ChebitWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChebitWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :authenticated do
    plug ChebitWeb.Plugs.Authenticate
  end

  scope "/", ChebitWeb do
    pipe_through :api

    get "/healthz", HealthController, :show
  end

  # No `accepts` check: a provider sends whatever Accept header it wants. The signature
  # of the body is the only gate.
  scope "/webhooks", ChebitWeb do
    post "/:provider", WebhookController, :create
  end

  scope "/v1", ChebitWeb do
    pipe_through [:api, :authenticated]

    post "/payment_intents", PaymentIntentController, :create
    get "/payment_intents/:id", PaymentIntentController, :show
    post "/payment_intents/:id/confirm", PaymentIntentController, :confirm
    get "/balances", BalanceController, :index
  end

  # The dashboard shows the data of every merchant, so it exists only where dev routes are on.
  if Application.compile_env(:chebit, :dev_routes) do
    scope "/", ChebitWeb do
      pipe_through :browser

      live "/dashboard", DashboardLive
    end
  end
end
