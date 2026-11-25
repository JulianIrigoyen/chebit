defmodule Chebit.Ledger.ConcurrencyTest do
  use Chebit.UnboxedCase

  alias Chebit.Fixtures
  alias Chebit.Ledger
  alias Chebit.Ledger.Account
  alias Chebit.Ledger.Audit
  alias Chebit.Ledger.Hold
  alias Chebit.Ledger.Transaction

  defp transfer(from, to, amount, source_id) do
    %{
      kind: "transfer",
      source_type: "race",
      source_id: source_id,
      entries: [
        %{account_id: from.id, direction: :debit, amount_minor: amount, currency: from.currency},
        %{account_id: to.id, direction: :credit, amount_minor: amount, currency: to.currency}
      ]
    }
  end

  defp balance!(account) do
    {:ok, balance} = Ledger.balance(account.id)
    balance
  end

  defp funded(amount) do
    account = Fixtures.customer_account()
    Fixtures.fund(account, amount)
    account
  end

  test "30 debits of 10 against a balance of 100: 10 succeed, 20 are refused" do
    from = funded(100)
    to = Fixtures.customer_account()

    results =
      race(for n <- 1..30, do: fn -> Ledger.post(transfer(from, to, 10, "debit-#{n}")) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 10
    assert Enum.count(results, &(&1 == {:error, :insufficient_funds})) == 20
    assert balance!(from).balance_minor == 0
    assert balance!(to).balance_minor == 100
    assert Audit.run() == []
  end

  test "30 holds of 10 on an available balance of 100: 10 succeed" do
    account = funded(100)

    results =
      race(
        for n <- 1..30 do
          fn ->
            Ledger.place_hold(%{
              account_id: account.id,
              amount_minor: 10,
              source_type: "race",
              source_id: "hold-#{n}"
            })
          end
        end
      )

    assert Enum.count(results, &match?({:ok, %Hold{}}, &1)) == 10
    assert Enum.count(results, &(&1 == {:error, :insufficient_funds})) == 20
    assert %{held_minor: 100, available_minor: 0} = balance!(account)
    assert Repo.aggregate(from(h in Hold, where: h.account_id == ^account.id), :count) == 10
    assert Audit.run() == []
  end

  test "the same post raced 20 times writes one transaction" do
    from = funded(100)
    to = Fixtures.customer_account()
    request = transfer(from, to, 10, "same")

    results = race(for _ <- 1..20, do: fn -> Ledger.post(request) end)

    assert [id] = results |> Enum.map(fn {:ok, transaction} -> transaction.id end) |> Enum.uniq()
    assert Repo.aggregate(from(t in Transaction, where: t.source_id == "same"), :count) == 1
    assert {:ok, %Transaction{id: ^id}} = Ledger.fetch_transaction("race", "same", "transfer")
    assert balance!(from).balance_minor == 90
    assert balance!(to).balance_minor == 10
    assert Audit.run() == []
  end

  test "transfers A to B and B to A raced 20 and 20 do not deadlock" do
    a = funded(1000)
    b = funded(1000)

    funs =
      for n <- 1..20 do
        [
          fn -> Ledger.post(transfer(a, b, n, "ab-#{n}")) end,
          fn -> Ledger.post(transfer(b, a, n, "ba-#{n}")) end
        ]
      end

    results = race(List.flatten(funs))

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert balance!(a).balance_minor == 1000
    assert balance!(b).balance_minor == 1000
    assert Audit.run() == []
  end

  test "release_hold raced against a capture: exactly one wins each time" do
    account = funded(1000)
    to = Fixtures.customer_account()

    outcomes =
      for n <- 1..20 do
        {:ok, hold} =
          Ledger.place_hold(%{
            account_id: account.id,
            amount_minor: 10,
            source_type: "race",
            source_id: "rc-#{n}"
          })

        [release, capture] =
          race([
            fn -> Ledger.release_hold(hold.id) end,
            fn -> Ledger.post(transfer(account, to, 10, "cap-#{n}"), capture_hold: hold.id) end
          ])

        assert Enum.count([release, capture], &match?({:ok, _}, &1)) == 1
        final = Repo.get!(Hold, hold.id)

        case {release, capture} do
          {{:ok, %Hold{status: :released}}, {:error, :hold_not_active}} ->
            assert final.status == :released

          {{:error, :hold_not_active}, {:ok, %Transaction{}}} ->
            assert final.status == :captured

          other ->
            flunk("unexpected outcome: #{inspect(other)}")
        end

        final.status
      end

    captured = Enum.count(outcomes, &(&1 == :captured))
    assert balance!(to).balance_minor == captured * 10
    assert balance!(account).balance_minor == 1000 - captured * 10
    assert balance!(account).held_minor == 0
    assert Audit.run() == []
  end

  test "ensure_account raced 20 times creates one account" do
    owner = {:merchant, Ecto.UUID.generate()}

    results = race(for _ <- 1..20, do: fn -> Ledger.ensure_account(owner, "balance", :ARS) end)

    assert [id] = results |> Enum.map(fn {:ok, account} -> account.id end) |> Enum.uniq()
    assert Repo.aggregate(from(a in Account, where: a.id == ^id), :count) == 1
    assert [_one] = Ledger.balances(owner)
  end

  test "ensure_account raced 20 times for a house account creates one account" do
    results =
      race(for _ <- 1..20, do: fn -> Ledger.ensure_account(:house, "race-house", :ARS) end)

    assert results |> Enum.map(fn {:ok, account} -> account.id end) |> Enum.uniq() |> length() ==
             1

    assert [_one] = Ledger.balances(:house) |> Enum.filter(&(&1.currency == :ARS))
  end
end
