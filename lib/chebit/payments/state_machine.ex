defmodule Chebit.Payments.StateMachine do
  @moduledoc """
  The payment state machine. It is the same for each provider.

  | From       | To                               |
  |------------|----------------------------------|
  | `created`  | `pending`, `failed`, `expired`   |
  | `pending`  | `paid`, `failed`, `expired`      |
  | `paid`     | `final`, `refunded`, `disputed`  |
  | `disputed` | `final`, `refunded`              |

  - `paid`: the provider accepted the payment. It can still reverse.
  - `disputed`: the payer contests a `paid` payment. A won dispute ends `final`, a lost one
    ends `refunded`.
  - `final`: the payment cannot reverse.
  - `final`, `failed`, `expired` and `refunded` are terminal. A terminal status has no exit.
  - The detail of a failure goes in `failure_reason`. It never becomes a new status.

  This module is pure. `Chebit.Payments` applies a transition and its ledger effect.
  A database trigger also refuses to change a terminal status.
  """

  @transitions %{
    created: [:pending, :failed, :expired],
    pending: [:paid, :failed, :expired],
    paid: [:final, :refunded, :disputed],
    disputed: [:final, :refunded],
    final: [],
    failed: [],
    expired: [],
    refunded: []
  }
  @statuses [:created, :pending, :paid, :disputed, :final, :failed, :expired, :refunded]
  @terminal [:final, :failed, :expired, :refunded]

  # A transition never lowers the rank. Tests use it to prove that the machine only moves forward.
  @ranks %{
    created: 0,
    pending: 1,
    paid: 2,
    disputed: 3,
    final: 4,
    failed: 4,
    expired: 4,
    refunded: 4
  }

  @type status ::
          :created | :pending | :paid | :disputed | :final | :failed | :expired | :refunded

  @doc "Lists each status."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Lists the terminal statuses."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal

  @doc "Returns true when the status has no exit."
  @spec terminal?(status()) :: boolean()
  def terminal?(status), do: status in @terminal

  @doc "Returns the position of a status in the forward order."
  @spec rank(status()) :: non_neg_integer()
  def rank(status), do: Map.fetch!(@ranks, status)

  @doc "Lists the statuses that `from` can move to in one step."
  @spec next(status()) :: [status()]
  def next(from), do: Map.fetch!(@transitions, from)

  @doc "Checks one step."
  @spec transition(status(), status()) :: :ok | {:error, :invalid_transition}
  def transition(from, to) do
    if to in Map.get(@transitions, from, []), do: :ok, else: {:error, :invalid_transition}
  end

  @doc """
  Returns the shortest list of steps from `from` to `to`.

  A provider reports its current status, not each step. `path/2` gives the steps that we
  missed, in order. The list is empty when `from` equals `to`.

      iex> Chebit.Payments.StateMachine.path(:pending, :final)
      {:ok, [:paid, :final]}
      iex> Chebit.Payments.StateMachine.path(:final, :refunded)
      {:error, :unreachable}
  """
  @spec path(status(), status()) :: {:ok, [status()]} | {:error, :unreachable}
  def path(from, from) when is_map_key(@transitions, from), do: {:ok, []}

  def path(from, to) when is_map_key(@transitions, from) and is_map_key(@transitions, to) do
    search([{from, []}], MapSet.new([from]), to)
  end

  def path(_from, _to), do: {:error, :unreachable}

  # Breadth-first search. The graph has 8 nodes and no cycle.
  defp search([], _seen, _to), do: {:error, :unreachable}

  defp search([{status, steps} | rest], seen, to) do
    candidates = Enum.reject(next(status), &MapSet.member?(seen, &1))

    if to in candidates do
      {:ok, Enum.reverse([to | steps])}
    else
      queue = rest ++ Enum.map(candidates, &{&1, [&1 | steps]})
      search(queue, Enum.reduce(candidates, seen, &MapSet.put(&2, &1)), to)
    end
  end
end
