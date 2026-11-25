defmodule Chebit.UnboxedCase do
  @moduledoc """
  The case for a test that needs real concurrency or a real COMMIT.

  The SQL sandbox wraps a test in one transaction on one connection, so two processes never
  really race and nothing ever commits. A test here runs outside the sandbox: each process
  gets its own connection, and each write commits.

  Always `use Chebit.UnboxedCase` without options. The case is `async: false`: it changes
  the mode of the shared pool, and it truncates each table before and after each test.
  TRUNCATE is not blocked by the append-only triggers.
  """
  use ExUnit.CaseTemplate

  alias Chebit.Repo
  alias Ecto.Adapters.SQL.Sandbox

  @tables ~w(outbox_events idempotency_keys provider_events payment_attempts payment_intents
             holds postings ledger_transactions accounts merchants oban_jobs)

  using do
    quote do
      alias Chebit.Repo

      import Ecto.Query
      import Chebit.UnboxedCase
    end
  end

  setup do
    Sandbox.mode(Repo, :auto)
    truncate!()

    on_exit(fn ->
      truncate!()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @doc "Empties each table."
  @spec truncate!() :: :ok
  def truncate! do
    Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} CASCADE")
    :ok
  end

  @doc """
  Runs each function in its own process at the same time and returns the results in order.

  Each process waits at a gate, so they all start their database work together.
  """
  @spec race([(-> result)]) :: [result] when result: term()
  def race(funs) do
    gate = make_ref()
    parent = self()

    tasks =
      for fun <- funs do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            ^gate -> fun.()
          end
        end)
      end

    for task <- tasks do
      pid = task.pid

      receive do
        {:ready, ^pid} -> :ok
      end
    end

    for task <- tasks, do: send(task.pid, gate)
    Task.await_many(tasks, 30_000)
  end
end
