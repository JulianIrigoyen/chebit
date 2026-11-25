defmodule Chebit.Ledger.Audit do
  @moduledoc """
  Checks the ledger invariants against the rows in the database.

  The constraints stop a bad write. This audit proves that the stored data still agrees
  with itself. Tests run it after each scenario, and `Chebit.Ledger.AuditWorker` runs it
  each hour.
  """

  alias Chebit.Repo

  @type check ::
          :transaction_unbalanced
          | :balance_cache_mismatch
          | :held_cache_mismatch
          | :negative_available
          | :currency_not_zero

  @type violation :: %{check: check(), subject: String.t(), detail: map()}

  @doc """
  Runs each check and lists what it found. An empty list means that each invariant holds.

  - `:transaction_unbalanced` - a transaction whose debits and credits differ for a currency.
    Subject: the transaction id.
  - `:balance_cache_mismatch` - an account whose `balance_minor` differs from credits minus
    debits of its postings. Subject: the account id.
  - `:held_cache_mismatch` - an account whose `held_minor` differs from the sum of its active
    holds. Subject: the account id.
  - `:negative_available` - a merchant or user account with `balance_minor - held_minor < 0`.
    Subject: the account id.
  - `:currency_not_zero` - a currency whose account balances do not sum to zero: money
    appeared or vanished. Subject: the currency.

  Each check is one SQL query. `detail` holds the numbers that differ.
  """
  @spec run() :: [violation()]
  def run do
    unbalanced() ++ balance_cache() ++ held_cache() ++ negative_available() ++ currency_not_zero()
  end

  # Sums are cast to text, so a large total never overflows a driver type.
  defp unbalanced do
    """
    SELECT transaction_id::text, currency,
           SUM(CASE direction WHEN 'debit' THEN amount_minor ELSE -amount_minor END)::text
    FROM postings
    GROUP BY transaction_id, currency
    HAVING SUM(CASE direction WHEN 'debit' THEN amount_minor ELSE -amount_minor END) <> 0
    ORDER BY transaction_id, currency
    """
    |> query(:transaction_unbalanced, fn [id, currency, diff] ->
      {id, %{currency: currency, debits_minus_credits_minor: String.to_integer(diff)}}
    end)
  end

  defp balance_cache do
    """
    SELECT a.id::text, a.balance_minor::text,
           COALESCE(SUM(CASE p.direction WHEN 'credit' THEN p.amount_minor ELSE -p.amount_minor END), 0)::text
    FROM accounts a
    LEFT JOIN postings p ON p.account_id = a.id
    GROUP BY a.id
    HAVING a.balance_minor <>
           COALESCE(SUM(CASE p.direction WHEN 'credit' THEN p.amount_minor ELSE -p.amount_minor END), 0)
    ORDER BY a.id
    """
    |> query(:balance_cache_mismatch, fn [id, cached, computed] ->
      {id,
       %{cached_minor: String.to_integer(cached), postings_minor: String.to_integer(computed)}}
    end)
  end

  defp held_cache do
    """
    SELECT a.id::text, a.held_minor::text, COALESCE(SUM(h.amount_minor), 0)::text
    FROM accounts a
    LEFT JOIN holds h ON h.account_id = a.id AND h.status = 'active'
    GROUP BY a.id
    HAVING a.held_minor <> COALESCE(SUM(h.amount_minor), 0)
    ORDER BY a.id
    """
    |> query(:held_cache_mismatch, fn [id, cached, computed] ->
      {id,
       %{cached_minor: String.to_integer(cached), active_holds_minor: String.to_integer(computed)}}
    end)
  end

  defp negative_available do
    """
    SELECT id::text, balance_minor::text, held_minor::text
    FROM accounts
    WHERE owner_type <> 'house' AND balance_minor - held_minor < 0
    ORDER BY id
    """
    |> query(:negative_available, fn [id, balance, held] ->
      {id, %{balance_minor: String.to_integer(balance), held_minor: String.to_integer(held)}}
    end)
  end

  defp currency_not_zero do
    """
    SELECT currency, SUM(balance_minor)::text
    FROM accounts
    GROUP BY currency
    HAVING SUM(balance_minor) <> 0
    ORDER BY currency
    """
    |> query(:currency_not_zero, fn [currency, sum] ->
      {currency, %{sum_minor: String.to_integer(sum)}}
    end)
  end

  defp query(sql, check, to_subject_detail) do
    %{rows: rows} = Repo.query!(sql)

    for row <- rows do
      {subject, detail} = to_subject_detail.(row)
      %{check: check, subject: subject, detail: detail}
    end
  end
end
