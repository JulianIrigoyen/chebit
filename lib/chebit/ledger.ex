defmodule Chebit.Ledger do
  @moduledoc """
  The double-entry ledger. No other module writes accounts, transactions, postings or holds.

  ## Model

  - A transaction is a group of postings. For each currency its debits equal its credits.
  - A posting is one debit or one credit of a positive amount on one account.
  - `Account.balance_minor` is credits minus debits. It is a cache. The postings are the truth,
    and `Chebit.Ledger.Audit` compares the two.
  - A hold reserves part of a balance. Available is `balance_minor - held_minor`.
  - The available balance of a merchant or user account is never negative. A house account
    can be negative.

  ## Rules that each function follows

  - It is idempotent on its source. A repeated call returns the first result and changes
    nothing. The same source with different content (entries, `reverses_id` or the hold to
    capture) gives `{:error, :source_conflict}`.
  - It runs in one database transaction (`Repo.transact/2`). A caller can call it inside its
    own transaction, and then both commit or both roll back.
  - Lock order: account rows in ascending id order (`FOR UPDATE`), then the hold row.
  - The application check comes first and returns an error atom. The database constraint is
    the backstop.
  - One `INSERT` writes all the postings of a transaction. The trigger `postings_balanced`
    checks the sum for each statement.
  - Inside a transaction, never let a statement fail on a constraint and then continue:
    Postgres aborts the whole transaction. Use `on_conflict: :nothing` and read the row.
  """

  import Ecto.Query

  alias Chebit.Ledger.Account
  alias Chebit.Ledger.Hold
  alias Chebit.Ledger.Posting
  alias Chebit.Ledger.Rules
  alias Chebit.Ledger.Transaction
  alias Chebit.Money
  alias Chebit.Repo

  @type owner :: :house | {:merchant, Ecto.UUID.t()} | {:user, Ecto.UUID.t()}

  @type entry :: %{
          account_id: Ecto.UUID.t(),
          direction: :debit | :credit,
          amount_minor: Money.amount_minor(),
          currency: Money.currency()
        }

  @type request :: %{
          required(:kind) => String.t(),
          required(:source_type) => String.t(),
          required(:source_id) => String.t(),
          required(:entries) => [entry()],
          optional(:metadata) => map(),
          optional(:reverses_id) => Ecto.UUID.t()
        }

  @type hold_request :: %{
          account_id: Ecto.UUID.t(),
          amount_minor: Money.amount_minor(),
          source_type: String.t(),
          source_id: String.t()
        }

  @type balance :: %{
          account_id: Ecto.UUID.t(),
          kind: String.t(),
          currency: Money.currency(),
          balance_minor: integer(),
          held_minor: non_neg_integer(),
          available_minor: integer()
        }

  @type post_error ::
          :invalid_request
          | :unbalanced
          | :account_not_found
          | :currency_mismatch
          | :insufficient_funds
          | :balance_out_of_range
          | :source_conflict
          | :hold_not_found
          | :hold_not_active
          | :hold_mismatch

  @doc """
  Returns the account of `owner` for `kind` and `currency`. Creates it when it does not exist.

  Two callers at the same time get the same account.
  """
  @spec ensure_account(owner(), String.t(), Money.currency()) ::
          {:ok, Account.t()} | {:error, :invalid_request}
  def ensure_account(owner, kind, currency) do
    with {:ok, {owner_type, owner_id}} <- owner_parts(owner),
         true <- is_binary(kind) and kind != "",
         true <- Money.valid_currency?(currency) do
      Repo.transact(fn ->
        {_count, _} =
          Repo.insert_all(
            Account,
            [
              %{
                id: Ecto.UUID.generate(),
                owner_type: owner_type,
                owner_id: owner_id,
                kind: kind,
                currency: currency,
                inserted_at: now()
              }
            ],
            on_conflict: :nothing
          )

        # Read after the insert: a concurrent insert of the same key has committed by now.
        {:ok, Repo.one!(account_by_key(owner_type, owner_id, kind, currency))}
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp account_by_key(owner_type, owner_id, kind, currency) do
    base = from(a in Account, where: a.owner_type == ^owner_type and a.kind == ^kind)
    base = from(a in base, where: a.currency == ^currency)

    if owner_id,
      do: from(a in base, where: a.owner_id == ^owner_id),
      else: from(a in base, where: is_nil(a.owner_id))
  end

  defp owner_parts(:house), do: {:ok, {:house, nil}}

  defp owner_parts({type, id}) when type in [:merchant, :user] do
    if uuid?(id), do: {:ok, {type, id}}, else: {:error, :invalid_request}
  end

  defp owner_parts(_owner), do: {:error, :invalid_request}

  defp uuid?(value), do: is_binary(value) and Ecto.UUID.cast(value) == {:ok, value}

  defp now, do: DateTime.utc_now()

  @doc """
  Writes one transaction and updates the balance of each account in it.

  Steps, in one database transaction:

  1. `Chebit.Ledger.Rules.validate/1` checks the request. No database call.
  2. Insert the transaction row with `on_conflict: :nothing` on `(source_type, source_id, kind)`.
     If the row exists, compare its postings with the request: equal gives `{:ok, existing}`,
     different gives `{:error, :source_conflict}`. Nothing else happens.
  3. Lock the accounts in ascending id order.
  4. With `capture_hold: hold_id`, lock the hold. It must be active, and the request must
     debit the account of the hold by exactly the amount of the hold.
  5. `Chebit.Ledger.Rules.apply_entries/3` computes the new balances or an error. No database call.
  6. Insert the postings in one statement. Update the balances.
  7. With `capture_hold`, mark the hold `captured`, set `capture_transaction_id`, and lower
     `held_minor` by the amount of the hold.

  ## Options

  - `:capture_hold` - the id of an active hold that this transaction consumes.
  """
  @spec post(request(), capture_hold: Ecto.UUID.t()) ::
          {:ok, Transaction.t()} | {:error, post_error()}
  def post(request, opts \\ []) do
    with :ok <- Rules.validate(request),
         {:ok, capture_hold} <- capture_hold_opt(opts) do
      Repo.transact(fn -> do_post(request, capture_hold) end)
    end
  end

  defp capture_hold_opt(opts) when is_list(opts) do
    case Keyword.keyword?(opts) and Keyword.get(opts, :capture_hold) do
      nil -> {:ok, nil}
      false -> {:error, :invalid_request}
      id -> if uuid?(id), do: {:ok, id}, else: {:error, :invalid_request}
    end
  end

  defp capture_hold_opt(_opts), do: {:error, :invalid_request}

  defp do_post(request, capture_hold) do
    id = Ecto.UUID.generate()

    with :ok <- check_reverses(request),
         {:ok, inserted?} <- insert_transaction(id, request) do
      if inserted? do
        write_transaction(id, request, capture_hold)
      else
        replay(request, capture_hold)
      end
    end
  end

  # A request that names `reverses_id` must be the exact mirror of that transaction, and
  # that transaction must not be a reversal itself. Else an unrelated transaction could
  # take the one reversal that each transaction has.
  defp check_reverses(%{reverses_id: reverses_id} = request) do
    case Repo.get(Transaction, reverses_id) do
      %Transaction{reverses_id: nil} = original ->
        postings = Repo.all(from(p in Posting, where: p.transaction_id == ^original.id))
        if Rules.reverses?(postings, request.entries), do: :ok, else: {:error, :invalid_request}

      _missing_or_reversal ->
        {:error, :invalid_request}
    end
  end

  defp check_reverses(_request), do: :ok

  defp insert_transaction(id, request) do
    row = %{
      id: id,
      kind: request.kind,
      source_type: request.source_type,
      source_id: request.source_id,
      reverses_id: Map.get(request, :reverses_id),
      metadata: Map.get(request, :metadata, %{}),
      inserted_at: now()
    }

    {count, _} = Repo.insert_all(Transaction, [row], on_conflict: :nothing)
    {:ok, count == 1}
  end

  # The source exists already. An equal request gets the first result.
  defp replay(request, capture_hold) do
    case fetch_transaction(request.source_type, request.source_id, request.kind) do
      {:ok, existing} ->
        if same_request?(existing, request) and captured_by?(capture_hold, existing),
          do: {:ok, existing},
          else: {:error, :source_conflict}

      # A unique index other than the source refused the row: it reverses a transaction twice.
      {:error, :transaction_not_found} ->
        {:error, :source_conflict}
    end
  end

  defp same_request?(existing, request) do
    existing.reverses_id == Map.get(request, :reverses_id) and
      Rules.same_entries?(existing.postings, request.entries)
  end

  # A replay that names a hold must name the hold that the first call captured. Else the
  # caller would get `:ok` for a hold that is still active.
  defp captured_by?(nil, _existing), do: true

  defp captured_by?(hold_id, existing) do
    Repo.exists?(
      from(h in Hold, where: h.id == ^hold_id and h.capture_transaction_id == ^existing.id)
    )
  end

  defp write_transaction(id, request, capture_hold) do
    ids = request.entries |> Enum.map(& &1.account_id) |> Enum.uniq() |> Enum.sort()
    accounts = lock_accounts(ids)

    with {:ok, hold} <- lock_capture_hold(capture_hold),
         {:ok, changes} <- Rules.apply_entries(accounts, request.entries, hold) do
      timestamp = now()

      rows =
        for entry <- request.entries do
          %{
            transaction_id: id,
            currency: entry.currency,
            account_id: entry.account_id,
            direction: entry.direction,
            amount_minor: entry.amount_minor,
            inserted_at: timestamp
          }
        end

      {_count, _} = Repo.insert_all(Posting, rows)
      apply_changes(changes)
      if hold, do: capture(hold, id, timestamp)

      {:ok, load_transaction(id)}
    end
  end

  defp lock_accounts(ids) do
    Repo.all(from(a in Account, where: a.id in ^ids, order_by: a.id, lock: "FOR UPDATE"))
  end

  defp lock_capture_hold(nil), do: {:ok, nil}

  defp lock_capture_hold(hold_id) do
    case Repo.one(from(h in Hold, where: h.id == ^hold_id, lock: "FOR UPDATE")) do
      nil -> {:error, :hold_not_found}
      hold -> {:ok, hold}
    end
  end

  defp apply_changes(changes) do
    for {account_id, change} <- Enum.sort(changes) do
      from(a in Account, where: a.id == ^account_id)
      |> Repo.update_all(
        inc: [balance_minor: change.balance_delta_minor, held_minor: change.held_delta_minor]
      )
    end
  end

  # `apply_changes/1` already lowered `held_minor`.
  defp capture(hold, transaction_id, timestamp) do
    from(h in Hold, where: h.id == ^hold.id)
    |> Repo.update_all(
      set: [status: :captured, capture_transaction_id: transaction_id, updated_at: timestamp]
    )
  end

  defp load_transaction(id) do
    Transaction
    |> Repo.get!(id)
    |> Repo.preload(postings: from(p in Posting, order_by: p.id))
  end

  @doc """
  Writes the transaction that undoes `transaction_id`: the same postings with the direction
  swapped, and `reverses_id` set.

  The source of the new transaction is `("ledger_transaction", transaction_id, "reversal")`,
  so a transaction is reversed at most once and a repeated call returns the first reversal.
  A reversal of a reversal is refused with `{:error, :invalid_request}`.

  ## Options

  - `:capture_hold` - same as in `post/2`.
  """
  @spec reverse(Ecto.UUID.t(), capture_hold: Ecto.UUID.t()) ::
          {:ok, Transaction.t()} | {:error, :transaction_not_found | post_error()}
  def reverse(transaction_id, opts \\ []) do
    with true <- uuid?(transaction_id),
         {:ok, capture_hold} <- capture_hold_opt(opts) do
      Repo.transact(fn -> do_reverse(transaction_id, capture_hold) end)
    else
      false -> {:error, :transaction_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp do_reverse(transaction_id, capture_hold) do
    case Repo.get(Transaction, transaction_id) do
      nil ->
        {:error, :transaction_not_found}

      %Transaction{reverses_id: reverses_id} when not is_nil(reverses_id) ->
        {:error, :invalid_request}

      original ->
        original = Repo.preload(original, postings: from(p in Posting, order_by: p.id))

        do_post(
          %{
            kind: "reversal",
            source_type: "ledger_transaction",
            source_id: original.id,
            entries: Rules.reversal_entries(original.postings),
            reverses_id: original.id
          },
          capture_hold
        )
    end
  end

  @doc """
  Reserves `amount_minor` of the available balance of an account.

  Steps, in one database transaction: lock the account; look for a hold with the same
  source; if it exists and has the same account and amount, return it and change nothing
  (a different account or amount gives `{:error, :source_conflict}`); else check that
  available is at least the amount, raise `held_minor`, and insert the hold.
  """
  @spec place_hold(hold_request()) ::
          {:ok, Hold.t()}
          | {:error,
             :invalid_request | :account_not_found | :insufficient_funds | :source_conflict}
  def place_hold(request) do
    if valid_hold_request?(request) do
      Repo.transact(fn -> do_place_hold(request) end)
    else
      {:error, :invalid_request}
    end
  end

  defp valid_hold_request?(request) when is_map(request) do
    uuid?(Map.get(request, :account_id)) and
      Money.valid_amount?(Map.get(request, :amount_minor)) and
      Enum.all?([:source_type, :source_id], fn key ->
        value = Map.get(request, key)
        is_binary(value) and value != ""
      end)
  end

  defp valid_hold_request?(_request), do: false

  defp do_place_hold(request) do
    case lock_accounts([request.account_id]) do
      [] ->
        {:error, :account_not_found}

      [account] ->
        case fetch_hold(request.source_type, request.source_id) do
          {:ok, hold} -> same_hold(hold, request)
          {:error, :hold_not_found} -> insert_hold(account, request)
        end
    end
  end

  defp same_hold(hold, request) do
    if hold.account_id == request.account_id and hold.amount_minor == request.amount_minor,
      do: {:ok, hold},
      else: {:error, :source_conflict}
  end

  defp insert_hold(account, request) do
    if account.balance_minor - account.held_minor < request.amount_minor do
      {:error, :insufficient_funds}
    else
      timestamp = now()

      row = %{
        id: Ecto.UUID.generate(),
        account_id: request.account_id,
        amount_minor: request.amount_minor,
        status: :active,
        source_type: request.source_type,
        source_id: request.source_id,
        inserted_at: timestamp,
        updated_at: timestamp
      }

      case Repo.insert_all(Hold, [row], on_conflict: :nothing) do
        {1, _} ->
          from(a in Account, where: a.id == ^account.id)
          |> Repo.update_all(inc: [held_minor: request.amount_minor])

          {:ok, Repo.get!(Hold, row.id)}

        # Another caller placed this source on another account since our lookup.
        {0, _} ->
          {:ok, hold} = fetch_hold(request.source_type, request.source_id)
          same_hold(hold, request)
      end
    end
  end

  @doc """
  Ends an active hold and makes its amount available again.

  A hold that is already released gives `{:ok, hold}` and changes nothing. A captured hold
  gives `{:error, :hold_not_active}`.
  """
  @spec release_hold(Ecto.UUID.t()) ::
          {:ok, Hold.t()} | {:error, :hold_not_found | :hold_not_active}
  def release_hold(hold_id) do
    if uuid?(hold_id) do
      Repo.transact(fn -> do_release_hold(hold_id) end)
    else
      {:error, :hold_not_found}
    end
  end

  # Lock order is the same as in `post/2`: the account first, then the hold.
  defp do_release_hold(hold_id) do
    case Repo.get(Hold, hold_id) do
      nil ->
        {:error, :hold_not_found}

      %Hold{account_id: account_id} ->
        lock_accounts([account_id])

        case lock_capture_hold(hold_id) do
          {:ok, %Hold{status: :active} = hold} -> end_hold(hold)
          {:ok, %Hold{status: :released} = hold} -> {:ok, hold}
          {:ok, %Hold{}} -> {:error, :hold_not_active}
          {:error, :hold_not_found} -> {:error, :hold_not_found}
        end
    end
  end

  defp end_hold(hold) do
    from(h in Hold, where: h.id == ^hold.id)
    |> Repo.update_all(set: [status: :released, updated_at: now()])

    from(a in Account, where: a.id == ^hold.account_id)
    |> Repo.update_all(inc: [held_minor: -hold.amount_minor])

    {:ok, Repo.get!(Hold, hold.id)}
  end

  @doc "Finds the hold that an operation placed."
  @spec fetch_hold(String.t(), String.t()) :: {:ok, Hold.t()} | {:error, :hold_not_found}
  def fetch_hold(source_type, source_id) when is_binary(source_type) and is_binary(source_id) do
    query = from(h in Hold, where: h.source_type == ^source_type and h.source_id == ^source_id)

    case Repo.one(query) do
      %Hold{} = hold -> {:ok, hold}
      nil -> {:error, :hold_not_found}
    end
  end

  def fetch_hold(_source_type, _source_id), do: {:error, :hold_not_found}

  @doc "Finds the transaction that an operation wrote, with its postings loaded."
  @spec fetch_transaction(String.t(), String.t(), String.t()) ::
          {:ok, Transaction.t()} | {:error, :transaction_not_found}
  def fetch_transaction(source_type, source_id, kind)
      when is_binary(source_type) and is_binary(source_id) and is_binary(kind) do
    query =
      from(t in Transaction,
        where: t.source_type == ^source_type and t.source_id == ^source_id and t.kind == ^kind,
        preload: [postings: ^from(p in Posting, order_by: p.id)]
      )

    case Repo.one(query) do
      %Transaction{} = transaction -> {:ok, transaction}
      nil -> {:error, :transaction_not_found}
    end
  end

  def fetch_transaction(_source_type, _source_id, _kind), do: {:error, :transaction_not_found}

  @doc "Reads the cached balance of an account."
  @spec balance(Ecto.UUID.t()) :: {:ok, balance()} | {:error, :account_not_found}
  def balance(account_id) do
    case uuid?(account_id) and Repo.get(Account, account_id) do
      %Account{} = account -> {:ok, to_balance(account)}
      _ -> {:error, :account_not_found}
    end
  end

  defp to_balance(account) do
    %{
      account_id: account.id,
      kind: account.kind,
      currency: account.currency,
      balance_minor: account.balance_minor,
      held_minor: account.held_minor,
      available_minor: account.balance_minor - account.held_minor
    }
  end

  @doc """
  Lists the accounts of all owners, ordered by owner type, kind and currency.

  `limit` caps the rows. The dev dashboard uses this call.
  """
  @spec list_accounts(pos_integer()) :: [
          %{
            balance: balance(),
            owner_type: :house | :merchant | :user,
            owner_id: Ecto.UUID.t() | nil
          }
        ]
  def list_accounts(limit \\ 100) when is_integer(limit) and limit > 0 do
    from(a in Account, order_by: [a.owner_type, a.kind, a.currency, a.id], limit: ^limit)
    |> Repo.all()
    |> Enum.map(&%{balance: to_balance(&1), owner_type: &1.owner_type, owner_id: &1.owner_id})
  end

  @doc "Lists the balance of each account of an owner, ordered by kind and currency."
  @spec balances(owner()) :: [balance()]
  def balances(owner) do
    case owner_parts(owner) do
      {:ok, {owner_type, owner_id}} ->
        base = from(a in Account, where: a.owner_type == ^owner_type)

        query =
          if owner_id,
            do: from(a in base, where: a.owner_id == ^owner_id),
            else: from(a in base, where: is_nil(a.owner_id))

        from(a in query, order_by: [a.kind, a.currency])
        |> Repo.all()
        |> Enum.map(&to_balance/1)

      {:error, _reason} ->
        []
    end
  end
end
