defmodule Chebit.Repo do
  use Ecto.Repo,
    otp_app: :chebit,
    adapter: Ecto.Adapters.Postgres
end
