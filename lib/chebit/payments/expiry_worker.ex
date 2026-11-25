defmodule Chebit.Payments.ExpiryWorker do
  @moduledoc """
  Expires the intents that passed `expires_at` without a payment. Runs each minute.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Chebit.Payments

  @impl Oban.Worker
  def perform(_job) do
    {:ok, _count} = Payments.expire_due(DateTime.utc_now())
    :ok
  end
end
