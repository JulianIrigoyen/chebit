defmodule Chebit.Ledger.AuditWorker do
  @moduledoc """
  Runs `Chebit.Ledger.Audit` each hour. A violation is logged as an error.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Chebit.Ledger.Audit

  @impl Oban.Worker
  def perform(_job) do
    case Audit.run() do
      [] ->
        :ok

      violations ->
        Logger.error(
          "ledger audit found #{length(violations)} violations: #{inspect(violations)}"
        )

        {:error, :ledger_invariant_violated}
    end
  end
end
