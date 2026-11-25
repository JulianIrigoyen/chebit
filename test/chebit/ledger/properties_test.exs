defmodule Chebit.Ledger.PropertiesTest do
  use Chebit.DataCase, async: true
  use ExUnitProperties

  alias Chebit.Fixtures
  alias Chebit.Ledger
  alias Chebit.Ledger.Account
  alias Chebit.Ledger.Audit

  @currencies [:ARS, :USD]

  # Each currency has 5 accounts: customers 0..2 and houses 3..4.
  defp account_index, do: StreamData.integer(0..4)
  defp currency, do: StreamData.member_of(@currencies)

  defp amount,
    do: StreamData.frequency([{4, StreamData.integer(1..200)}, {1, StreamData.integer(1..5000)}])

  defp pick, do: StreamData.integer(0..1000)

  defp operation do
    StreamData.frequency([
      {5,
       StreamData.tuple(
         {StreamData.constant(:post), currency(), account_index(), account_index(), amount()}
       )},
      {3,
       StreamData.tuple(
         {StreamData.constant(:fund), currency(), StreamData.integer(0..2), amount()}
       )},
      {2,
       StreamData.tuple(
         {StreamData.constant(:unbalanced), currency(), account_index(), account_index(),
          amount()}
       )},
      {3,
       StreamData.tuple(
         {StreamData.constant(:hold), currency(), StreamData.integer(0..2), amount()}
       )},
      {2, StreamData.tuple({StreamData.constant(:release), pick()})},
      {3, StreamData.tuple({StreamData.constant(:capture), pick(), account_index()})},
      {2, StreamData.tuple({StreamData.constant(:reverse), pick()})},
      {3, StreamData.tuple({StreamData.constant(:replay), pick()})}
    ])
  end

  defp build_pool do
    for ccy <- @currencies, into: %{} do
      customers = for _ <- 1..3, do: Fixtures.customer_account(ccy)
      houses = for _ <- 1..2, do: Fixtures.house_account(ccy)
      {ccy, customers ++ houses}
    end
  end

  defp request(from, to, amount, source_id, credit_amount \\ nil) do
    %{
      kind: "transfer",
      source_type: "prop",
      source_id: source_id,
      entries: [
        %{account_id: from.id, direction: :debit, amount_minor: amount, currency: from.currency},
        %{
          account_id: to.id,
          direction: :credit,
          amount_minor: credit_amount || amount,
          currency: to.currency
        }
      ]
    }
  end

  defp snapshot(ids) do
    Repo.all(
      from(a in Account, where: a.id in ^ids, select: {a.id, a.balance_minor, a.held_minor})
    )
    |> Enum.sort()
  end

  # Runs one operation. Returns {result, state, replayable}, where `replayable` is a function
  # that repeats the call, or nil.
  defp run_op({:post, ccy, from, to, amount}, state) do
    {from, to} = {Enum.at(state.pool[ccy], from), Enum.at(state.pool[ccy], to)}
    req = request(from, to, amount, "op-#{state.run}-#{state.n}")
    call = fn -> Ledger.post(req) end
    {call.(), :post, call}
  end

  defp run_op({:fund, ccy, customer, amount}, state) do
    pool = state.pool[ccy]
    req = request(Enum.at(pool, 3), Enum.at(pool, customer), amount, "op-#{state.run}-#{state.n}")
    call = fn -> Ledger.post(req) end
    {call.(), :post, call}
  end

  defp run_op({:unbalanced, ccy, from, to, amount}, state) do
    {from, to} = {Enum.at(state.pool[ccy], from), Enum.at(state.pool[ccy], to)}
    req = request(from, to, amount, "op-#{state.run}-#{state.n}", amount + 1)
    {Ledger.post(req), :unbalanced, nil}
  end

  defp run_op({:hold, ccy, customer, amount}, state) do
    account = Enum.at(state.pool[ccy], customer)

    req = %{
      account_id: account.id,
      amount_minor: amount,
      source_type: "prop",
      source_id: "op-#{state.run}-#{state.n}"
    }

    call = fn -> Ledger.place_hold(req) end
    {call.(), :hold, call}
  end

  defp run_op({:release, k}, state) do
    case pick_from(state.holds, k) do
      nil -> {:skip, :skip, nil}
      {hold, _account} -> {Ledger.release_hold(hold.id), :release, nil}
    end
  end

  defp run_op({:capture, k, to}, state) do
    case pick_from(state.holds, k) do
      nil ->
        {:skip, :skip, nil}

      {hold, account} ->
        to = Enum.at(state.pool[account.currency], to)
        req = request(account, to, hold.amount_minor, "op-#{state.run}-#{state.n}")
        {Ledger.post(req, capture_hold: hold.id), :capture, nil}
    end
  end

  defp run_op({:reverse, k}, state) do
    case pick_from(state.txs, k) do
      nil -> {:skip, :skip, nil}
      tx -> {Ledger.reverse(tx.id), :reverse, nil}
    end
  end

  defp run_op({:replay, k}, state) do
    case pick_from(state.replays, k) do
      nil -> {:skip, :skip, nil}
      {first, call} -> {call.(), {:replay, first}, nil}
    end
  end

  defp pick_from([], _k), do: nil
  defp pick_from(list, k), do: Enum.at(list, rem(k, length(list)))

  defp record({:ok, %{postings: _} = tx}, :post, call, state),
    do: %{state | txs: state.txs ++ [tx], replays: state.replays ++ [{tx, call}]}

  defp record({:ok, %{amount_minor: _} = hold}, :hold, call, state) do
    account = Enum.find(state.all, &(&1.id == hold.account_id))
    %{state | holds: state.holds ++ [{hold, account}], replays: state.replays ++ [{hold, call}]}
  end

  defp record(_result, _kind, _call, state), do: state

  property "any sequence of operations keeps the ledger audit clean" do
    check all ops <- StreamData.list_of(operation(), max_length: 25), max_runs: 40 do
      pool = build_pool()

      # Start with funds, so that holds and captures have something to work on.
      for {_ccy, accounts} <- pool,
          customer <- Enum.take(accounts, 3),
          do: Fixtures.fund(customer, 300)

      all = pool |> Map.values() |> List.flatten()
      ids = Enum.map(all, & &1.id)

      state = %{
        run: System.unique_integer([:positive]),
        pool: pool,
        all: all,
        n: 0,
        holds: [],
        txs: [],
        replays: []
      }

      Enum.reduce(ops, state, fn op, state ->
        before = snapshot(ids)
        {result, kind, call} = run_op(op, state)

        case {kind, result} do
          {:skip, _} ->
            :ok

          {{:replay, first}, {:ok, again}} ->
            assert again.id == first.id
            assert snapshot(ids) == before

          {_, {:error, _reason}} ->
            assert snapshot(ids) == before, "a failed #{inspect(op)} changed a balance"

          {:unbalanced, other} ->
            flunk("an unbalanced post returned #{inspect(other)}")

          {_, {:ok, _}} ->
            :ok
        end

        if kind == :unbalanced, do: assert(result == {:error, :unbalanced})
        if match?({:replay, _}, kind), do: assert(match?({:ok, _}, result))

        record(result, kind, call, %{state | n: state.n + 1})
        |> Map.put(:n, state.n + 1)
      end)

      assert Audit.run() == []
    end
  end
end
