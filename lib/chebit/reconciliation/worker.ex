defmodule Chebit.Reconciliation.Worker do
  @moduledoc """
  Reconciles each provider with the ledger. Runs each hour. A mismatch is logged as an error.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Chebit.Reconciliation

  @impl Oban.Worker
  def perform(_job) do
    case Reconciliation.run_all() do
      {:ok, []} ->
        :ok

      {:ok, providers} ->
        Logger.error("reconciliation does not match for: #{Enum.join(providers, ", ")}")
        {:error, :reconciliation_mismatch}
    end
  end
end
