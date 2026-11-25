defmodule Chebit.Ledger.Rules do
  @moduledoc """
  The pure rules of the ledger: a request and the current balances in, a result or an error out.

  This module calls no Repo and reads no clock. `Chebit.Ledger` loads and locks the rows,
  calls these functions, and writes what they return.
  """

  alias Chebit.Ledger
  alias Chebit.Ledger.Account
  alias Chebit.Ledger.Hold
  alias Chebit.Ledger.Posting
  alias Chebit.Money

  @type change :: %{balance_delta_minor: integer(), held_delta_minor: integer()}

  @doc """
  Checks a request without the database.

  - `kind`, `source_type` and `source_id` are non-empty strings.
  - There are at least two entries.
  - Each entry has a UUID `account_id`, a direction, a currency that the ledger accepts and
    an amount that `Chebit.Money.valid_amount?/1` accepts.
  - For each currency, the debits equal the credits. If not: `{:error, :unbalanced}`.

  Any other defect gives `{:error, :invalid_request}`. Input can be any term; the function
  never raises.
  """
  @spec validate(term()) :: :ok | {:error, :invalid_request | :unbalanced}
  def validate(request) when is_map(request) do
    with :ok <- check_strings(request),
         :ok <- check_optional(request),
         {:ok, entries} <- fetch_entries(request),
         :ok <- check_entries(entries) do
      check_balanced(entries)
    end
  end

  def validate(_request), do: {:error, :invalid_request}

  @doc """
  Computes the change of each account that the entries touch.

  `accounts` holds each account that an entry names. `hold` is the hold that the transaction
  captures, or nil.

  - An entry that names an account outside `accounts` gives `{:error, :account_not_found}`.
  - An entry whose currency differs from its account gives `{:error, :currency_mismatch}`.
  - A hold that is not active gives `{:error, :hold_not_active}`.
  - A hold whose account is not debited by exactly its amount, net of credits, gives
    `{:error, :hold_mismatch}`.
  - A merchant or user account whose available balance would go below zero gives
    `{:error, :insufficient_funds}`. A house account has no floor.
  - A balance that would leave the range of a `bigint` column gives
    `{:error, :balance_out_of_range}`. One amount always fits; a sum of many can not.

  A credit raises the balance and a debit lowers it. A captured hold lowers `held_minor` of
  its account by its amount.
  """
  @spec apply_entries([Account.t()], [Ledger.entry()], Hold.t() | nil) ::
          {:ok, %{Ecto.UUID.t() => change()}}
          | {:error,
             :account_not_found
             | :currency_mismatch
             | :insufficient_funds
             | :balance_out_of_range
             | :hold_not_active
             | :hold_mismatch}
  def apply_entries(accounts, entries, hold) do
    by_id = Map.new(accounts, &{&1.id, &1})

    with :ok <- check_accounts(by_id, entries),
         :ok <- check_hold(hold, entries) do
      changes = compute_changes(entries, hold)

      with :ok <- check_floor(by_id, changes),
           :ok <- check_range(by_id, changes) do
        {:ok, changes}
      end
    end
  end

  @doc """
  Returns true when stored postings and requested entries describe the same movement.

  The order of the entries does not matter. Two entries on the same account and direction
  equal one entry with their sum.
  """
  @spec same_entries?([Posting.t()], [Ledger.entry()]) :: boolean()
  def same_entries?(postings, entries), do: net_entries(postings) == net_entries(entries)

  @doc "Returns the entries that undo the postings: same accounts and amounts, direction swapped."
  @spec reversal_entries([Posting.t()]) :: [Ledger.entry()]
  def reversal_entries(postings) do
    for posting <- postings do
      %{
        account_id: posting.account_id,
        direction: flip(posting.direction),
        amount_minor: posting.amount_minor,
        currency: posting.currency
      }
    end
  end

  @doc "Returns true when the entries undo the postings exactly."
  @spec reverses?([Posting.t()], [Ledger.entry()]) :: boolean()
  def reverses?(postings, entries) do
    net_entries(reversal_entries(postings)) == net_entries(entries)
  end

  defp flip(:debit), do: :credit
  defp flip(:credit), do: :debit

  # Sums the amount for each account, direction and currency.
  defp net_entries(items) do
    Enum.reduce(items, %{}, fn item, acc ->
      Map.update(
        acc,
        {item.account_id, item.direction, item.currency},
        item.amount_minor,
        &(&1 + item.amount_minor)
      )
    end)
  end

  defp check_strings(request) do
    if Enum.all?([:kind, :source_type, :source_id], &non_empty_string?(Map.get(request, &1))) do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp check_optional(request) do
    metadata_ok = not Map.has_key?(request, :metadata) or is_map(request.metadata)
    reverses_ok = not Map.has_key?(request, :reverses_id) or uuid?(request.reverses_id)

    if metadata_ok and reverses_ok, do: :ok, else: {:error, :invalid_request}
  end

  defp fetch_entries(request) do
    case Map.get(request, :entries) do
      [_, _ | _] = entries -> if proper_list?(entries), do: {:ok, entries}, else: invalid()
      _ -> invalid()
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp invalid, do: {:error, :invalid_request}

  defp check_entries(entries) do
    if Enum.all?(entries, &valid_entry?/1), do: :ok, else: invalid()
  end

  defp valid_entry?(entry) when is_map(entry) do
    uuid?(Map.get(entry, :account_id)) and
      Map.get(entry, :direction) in [:debit, :credit] and
      Money.valid_currency?(Map.get(entry, :currency)) and
      Money.valid_amount?(Map.get(entry, :amount_minor))
  end

  defp valid_entry?(_entry), do: false

  defp uuid?(value), do: is_binary(value) and Ecto.UUID.cast(value) == {:ok, value}

  defp check_balanced(entries) do
    sums =
      Enum.reduce(entries, %{}, fn entry, acc ->
        Map.update(acc, entry.currency, signed(entry), &(&1 + signed(entry)))
      end)

    if Enum.all?(sums, fn {_currency, sum} -> sum == 0 end), do: :ok, else: {:error, :unbalanced}
  end

  defp signed(%{direction: :debit, amount_minor: amount}), do: amount
  defp signed(%{direction: :credit, amount_minor: amount}), do: -amount

  defp check_accounts(by_id, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case Map.fetch(by_id, entry.account_id) do
        :error ->
          {:halt, {:error, :account_not_found}}

        {:ok, %{currency: currency}} when currency != entry.currency ->
          {:halt, {:error, :currency_mismatch}}

        {:ok, _account} ->
          {:cont, :ok}
      end
    end)
  end

  defp check_hold(nil, _entries), do: :ok

  defp check_hold(%Hold{status: status}, _entries) when status != :active,
    do: {:error, :hold_not_active}

  # Net of debits and credits: a debit that a credit on the same account cancels moves
  # nothing out, so it must not capture the hold.
  defp check_hold(%Hold{} = hold, entries) do
    net_debit =
      for %{account_id: id} = entry <- entries, id == hold.account_id, reduce: 0 do
        sum -> sum + signed(entry)
      end

    if net_debit == hold.amount_minor, do: :ok, else: {:error, :hold_mismatch}
  end

  defp compute_changes(entries, hold) do
    changes =
      Enum.reduce(entries, %{}, fn entry, acc ->
        delta = -signed(entry)
        zero = %{balance_delta_minor: 0, held_delta_minor: 0}

        Map.update(
          acc,
          entry.account_id,
          %{zero | balance_delta_minor: delta},
          &%{&1 | balance_delta_minor: &1.balance_delta_minor + delta}
        )
      end)

    case hold do
      nil ->
        changes

      %Hold{account_id: id, amount_minor: amount} ->
        Map.update!(changes, id, &%{&1 | held_delta_minor: &1.held_delta_minor - amount})
    end
  end

  # The column is a bigint. Without this check Postgres raises "bigint out of range".
  defp check_range(by_id, changes) do
    max = Money.max_amount_minor()

    in_range? =
      Enum.all?(changes, fn {id, change} ->
        account = Map.fetch!(by_id, id)
        abs(account.balance_minor + change.balance_delta_minor) <= max
      end)

    if in_range?, do: :ok, else: {:error, :balance_out_of_range}
  end

  defp check_floor(by_id, changes) do
    Enum.reduce_while(Enum.sort(changes), :ok, fn {id, change}, :ok ->
      account = Map.fetch!(by_id, id)

      available =
        account.balance_minor + change.balance_delta_minor -
          (account.held_minor + change.held_delta_minor)

      if account.owner_type != :house and available < 0 do
        {:halt, {:error, :insufficient_funds}}
      else
        {:cont, :ok}
      end
    end)
  end
end
