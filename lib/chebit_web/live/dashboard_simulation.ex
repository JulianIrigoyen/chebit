defmodule ChebitWeb.DashboardSimulation do
  @moduledoc """
  Runs many simulated payments for the dev dashboard, in the background.

  - One run at a time. The run process registers under `#{inspect(__MODULE__)}`.
  - Payments run in parallel, `@concurrency` at a time, below the Repo pool size (10 in
    dev), so the dashboard can still read the database.
  - Each payment takes the same path as one click: create, confirm, the simulated payer
    pays, and the signed webhook goes through intake.
  - Progress goes out on the PubSub topic `"simulation"` as `{:simulation, progress}`, at
    most every `@report_ms`, and once at the end.
  - `cancel/0` kills the run. A payment cut in half stays in its last committed status:
    each step is its own transaction.
  """

  alias Chebit.Merchants
  alias Chebit.Payments
  alias Chebit.Providers.Simulated
  alias Chebit.Webhooks

  @topic "simulation"
  @concurrency 8
  @report_ms 250
  @dev_merchant "Dev Cafe"

  @type progress :: %{
          total: pos_integer(),
          done: non_neg_integer(),
          failed: non_neg_integer(),
          started_ms: integer(),
          elapsed_ms: non_neg_integer(),
          status: :running | :finished | :cancelled
        }

  @doc "The PubSub topic of the progress messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Runs one payment end to end. Returns `:ok` or `{:error, reason}`."
  @spec run_one(Merchants.Merchant.t()) :: :ok | {:error, term()}
  def run_one(merchant) do
    key = "dashboard-" <> Ecto.UUID.generate()

    with {:ok, intent} <-
           Payments.create_intent(merchant, key, %{
             "amount_minor" => Enum.random([50_000, 150_000, 250_000]),
             "currency" => "ARS",
             "description" => "dashboard simulation"
           }),
         {:ok, confirmed} <- Payments.confirm_intent(merchant.id, intent.id, "simulated"),
         {:ok, delivery} <- Simulated.pay(hd(confirmed.attempts).id, :instant),
         {:ok, _result} <- Webhooks.ingest("simulated", delivery.body, delivery.headers) do
      :ok
    end
  end

  @doc "Starts a run of `count` payments. Fails when a run is already going."
  @spec start(pos_integer()) :: :ok | {:error, :already_running | term()}
  def start(count) when is_integer(count) and count > 0 do
    caller = self()

    {:ok, pid} =
      Task.Supervisor.start_child(ChebitWeb.SimulationSupervisor, fn ->
        case safe_register() do
          :ok ->
            send(caller, {:simulation_started, self()})
            run(count)

          :taken ->
            send(caller, {:simulation_started, :taken})
        end
      end)

    receive do
      {:simulation_started, ^pid} -> :ok
      {:simulation_started, :taken} -> {:error, :already_running}
    after
      5_000 -> {:error, :timeout}
    end
  end

  @doc "Stops the current run, if there is one."
  @spec cancel() :: :ok
  def cancel do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        # The progress lives in the run process, so it dies with the kill. Each dashboard
        # keeps the last report it got and marks it as cancelled.
        Process.exit(pid, :kill)
        Phoenix.PubSub.broadcast(Chebit.PubSub, @topic, {:simulation_cancelled})
        :ok
    end
  end

  defp safe_register do
    Process.register(self(), __MODULE__)
    :ok
  rescue
    ArgumentError -> :taken
  end

  defp run(count) do
    {:ok, merchant} = Merchants.get_or_create(@dev_merchant)
    now = System.monotonic_time(:millisecond)

    progress = %{
      total: count,
      done: 0,
      failed: 0,
      started_ms: now,
      elapsed_ms: 0,
      status: :running
    }

    report(progress)

    final =
      1..count
      |> Task.async_stream(fn _n -> run_one(merchant) end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce({progress, now}, fn result, {acc, last_report} ->
        acc = count_result(acc, result)
        now = System.monotonic_time(:millisecond)

        if now - last_report >= @report_ms do
          report(acc)
          {acc, now}
        else
          {acc, last_report}
        end
      end)
      |> elem(0)

    report(%{final | status: :finished})
  end

  defp count_result(acc, {:ok, :ok}), do: %{acc | done: acc.done + 1}
  defp count_result(acc, _failure), do: %{acc | done: acc.done + 1, failed: acc.failed + 1}

  # The run stamps the elapsed time, so the rate stays fixed after the run ends.
  defp report(progress) do
    elapsed = System.monotonic_time(:millisecond) - progress.started_ms
    progress = %{progress | elapsed_ms: elapsed}
    Phoenix.PubSub.broadcast(Chebit.PubSub, @topic, {:simulation, progress})
  end
end
