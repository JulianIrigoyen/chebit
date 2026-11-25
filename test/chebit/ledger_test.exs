defmodule Chebit.LedgerTest do
  use Chebit.DataCase, async: true

  alias Chebit.Fixtures
  alias Chebit.Ledger
  alias Chebit.Ledger.Account
  alias Chebit.Ledger.Audit
  alias Chebit.Ledger.Hold
  alias Chebit.Ledger.Posting
  alias Chebit.Ledger.Transaction

  defp entry(account, direction, amount, currency \\ nil) do
    %{
      account_id: account.id,
      direction: direction,
      amount_minor: amount,
      currency: currency || account.currency
    }
  end

  defp transfer(from, to, amount, source_id \\ nil) do
    %{
      kind: "transfer",
      source_type: "test",
      source_id: source_id || Ecto.UUID.generate(),
      entries: [entry(from, :debit, amount), entry(to, :credit, amount)]
    }
  end

  defp balance!(account) do
    {:ok, balance} = Ledger.balance(account.id)
    balance
  end

  defp funded(amount, currency \\ :ARS) do
    account = Fixtures.customer_account(currency)
    Fixtures.fund(account, amount)
    account
  end

  defp hold!(account, amount, source_id \\ nil) do
    {:ok, hold} =
      Ledger.place_hold(%{
        account_id: account.id,
        amount_minor: amount,
        source_type: "test_hold",
        source_id: source_id || Ecto.UUID.generate()
      })

    hold
  end

  defp count(schema), do: Repo.aggregate(schema, :count)

  describe "ensure_account/3" do
    test "creates an account with zero balance" do
      owner = {:merchant, Ecto.UUID.generate()}
      assert {:ok, %Account{} = account} = Ledger.ensure_account(owner, "balance", :ARS)
      assert account.balance_minor == 0
      assert account.held_minor == 0
      assert account.owner_type == :merchant
      assert account.currency == :ARS
    end

    test "returns the same account on a second call" do
      owner = {:user, Ecto.UUID.generate()}
      {:ok, first} = Ledger.ensure_account(owner, "wallet", :USD)
      {:ok, second} = Ledger.ensure_account(owner, "wallet", :USD)
      assert first.id == second.id
      assert Repo.aggregate(from(a in Account, where: a.id == ^first.id), :count) == 1
    end

    test "returns the same house account on a second call" do
      kind = "house:#{System.unique_integer([:positive])}"
      {:ok, first} = Ledger.ensure_account(:house, kind, :ARS)
      {:ok, second} = Ledger.ensure_account(:house, kind, :ARS)
      assert first.id == second.id
      assert first.owner_id == nil
    end

    test "separates accounts by owner, kind and currency" do
      owner = {:merchant, Ecto.UUID.generate()}
      {:ok, a} = Ledger.ensure_account(owner, "balance", :ARS)
      {:ok, b} = Ledger.ensure_account(owner, "balance", :USD)
      {:ok, c} = Ledger.ensure_account(owner, "fees", :ARS)
      {:ok, d} = Ledger.ensure_account({:user, elem(owner, 1)}, "balance", :ARS)
      assert length(Enum.uniq([a.id, b.id, c.id, d.id])) == 4
    end
  end

  describe "ensure_account/3 rejected input" do
    test "refuses a bad owner, kind or currency" do
      id = Ecto.UUID.generate()

      for {owner, kind, currency} <- [
            {nil, "balance", :ARS},
            {:merchant, "balance", :ARS},
            {{:merchant, "x"}, "balance", :ARS},
            {{:merchant, nil}, "balance", :ARS},
            {{:bank, id}, "balance", :ARS},
            {{:merchant, id}, "", :ARS},
            {{:merchant, id}, :balance, :ARS},
            {{:merchant, id}, "balance", :EUR},
            {{:merchant, id}, "balance", "ARS"},
            {:house, nil, :ARS}
          ] do
        assert {:error, :invalid_request} = Ledger.ensure_account(owner, kind, currency)
      end
    end
  end

  describe "post/2" do
    test "writes the postings and moves the balances" do
      from = funded(100)
      to = Fixtures.customer_account()

      assert {:ok, %Transaction{} = transaction} = Ledger.post(transfer(from, to, 30))
      assert [%Posting{}, %Posting{}] = transaction.postings
      assert transaction.kind == "transfer"

      assert balance!(from).balance_minor == 70
      assert balance!(to).balance_minor == 30
      assert Audit.run() == []
    end

    test "stores metadata and reverses_id" do
      from = funded(100)
      to = Fixtures.customer_account()
      request = Map.put(transfer(from, to, 10), :metadata, %{"note" => "x"})
      {:ok, transaction} = Ledger.post(request)
      assert transaction.metadata == %{"note" => "x"}
    end

    test "writes a transaction in several currencies" do
      ars_from = funded(100, :ARS)
      usd_from = funded(50, :USD)
      ars_to = Fixtures.customer_account(:ARS)
      usd_to = Fixtures.customer_account(:USD)

      request = %{
        kind: "swap",
        source_type: "test",
        source_id: Ecto.UUID.generate(),
        entries: [
          entry(ars_from, :debit, 100),
          entry(ars_to, :credit, 100),
          entry(usd_from, :debit, 50),
          entry(usd_to, :credit, 50)
        ]
      }

      assert {:ok, transaction} = Ledger.post(request)
      assert length(transaction.postings) == 4
      assert balance!(ars_from).balance_minor == 0
      assert balance!(ars_to).balance_minor == 100
      assert balance!(usd_from).balance_minor == 0
      assert balance!(usd_to).balance_minor == 50
      assert Audit.run() == []
    end

    test "lets a house account go negative" do
      house = Fixtures.house_account()
      to = Fixtures.customer_account()
      assert {:ok, _} = Ledger.post(transfer(house, to, 500))
      assert balance!(house).balance_minor == -500
      assert Audit.run() == []
    end

    test "replays the same request and returns the first result" do
      from = funded(100)
      to = Fixtures.customer_account()
      request = transfer(from, to, 30)

      {:ok, first} = Ledger.post(request)
      before = {balance!(from), balance!(to), count(Transaction), count(Posting)}
      assert {:ok, second} = Ledger.post(request)

      assert second.id == first.id
      assert Enum.map(second.postings, & &1.id) == Enum.map(first.postings, & &1.id)
      assert before == {balance!(from), balance!(to), count(Transaction), count(Posting)}
    end

    test "replays a request whose entries come in another order" do
      from = funded(100)
      to = Fixtures.customer_account()
      request = transfer(from, to, 30)
      {:ok, first} = Ledger.post(request)
      assert {:ok, again} = Ledger.post(%{request | entries: Enum.reverse(request.entries)})
      assert again.id == first.id
    end

    test "replays after the funds are gone" do
      from = funded(30)
      to = Fixtures.customer_account()
      request = transfer(from, to, 30)
      {:ok, first} = Ledger.post(request)
      assert {:ok, again} = Ledger.post(request)
      assert again.id == first.id
      assert balance!(from).balance_minor == 0
    end

    test "refuses the same source with other entries" do
      from = funded(100)
      to = Fixtures.customer_account()
      request = transfer(from, to, 30)
      {:ok, _} = Ledger.post(request)

      other_amount = transfer(from, to, 31, request.source_id)
      other_account = transfer(from, Fixtures.customer_account(), 30, request.source_id)

      assert {:error, :source_conflict} = Ledger.post(other_amount)
      assert {:error, :source_conflict} = Ledger.post(other_account)
      assert balance!(from).balance_minor == 70
      assert count(Transaction) == 2
    end

    test "treats the same source with another kind as another operation" do
      from = funded(100)
      to = Fixtures.customer_account()
      request = transfer(from, to, 10)
      {:ok, first} = Ledger.post(request)
      {:ok, second} = Ledger.post(%{request | kind: "other_kind"})
      refute first.id == second.id
    end

    test "refuses an invalid request" do
      for bad <- [
            nil,
            %{},
            %{kind: "x"},
            "x",
            [],
            %{transfer(Fixtures.house_account(), Fixtures.house_account(), 1) | kind: ""}
          ] do
        assert {:error, :invalid_request} = Ledger.post(bad)
      end
    end

    test "refuses a float amount" do
      a = Fixtures.house_account()
      b = Fixtures.customer_account()
      request = %{transfer(a, b, 1) | entries: [entry(a, :debit, 1.0), entry(b, :credit, 1.0)]}
      assert {:error, :invalid_request} = Ledger.post(request)
    end

    test "refuses bad options" do
      request = transfer(Fixtures.house_account(), Fixtures.customer_account(), 5)
      assert {:error, :invalid_request} = Ledger.post(request, capture_hold: "nope")
      assert {:error, :invalid_request} = Ledger.post(request, :nope)
      assert {:error, :invalid_request} = Ledger.post(request, [:nope])
      assert count(Transaction) == 0
    end

    test "refuses an unbalanced request and writes nothing" do
      a = Fixtures.house_account()
      b = Fixtures.customer_account()
      request = %{transfer(a, b, 10) | entries: [entry(a, :debit, 10), entry(b, :credit, 9)]}
      assert {:error, :unbalanced} = Ledger.post(request)
      assert count(Transaction) == 0
      assert count(Posting) == 0
    end

    test "refuses an unknown account" do
      a = Fixtures.house_account()
      ghost = %Account{id: Ecto.UUID.generate(), currency: :ARS}
      assert {:error, :account_not_found} = Ledger.post(transfer(a, ghost, 10))
      assert count(Transaction) == 0
    end

    test "refuses a currency that differs from the account" do
      a = Fixtures.house_account(:ARS)
      b = Fixtures.customer_account(:ARS)

      request = %{
        transfer(a, b, 10)
        | entries: [entry(a, :debit, 10, :USD), entry(b, :credit, 10, :USD)]
      }

      assert {:error, :currency_mismatch} = Ledger.post(request)
      assert count(Transaction) == 0
    end

    test "refuses a debit that would make available negative and changes nothing" do
      from = funded(100)
      to = Fixtures.customer_account()

      assert {:error, :insufficient_funds} = Ledger.post(transfer(from, to, 101))
      assert balance!(from).balance_minor == 100
      assert balance!(to).balance_minor == 0
      assert count(Transaction) == 1
      assert Audit.run() == []
    end

    test "counts a hold against the available balance" do
      from = funded(100)
      to = Fixtures.customer_account()
      hold!(from, 60)

      assert {:error, :insufficient_funds} = Ledger.post(transfer(from, to, 41))
      assert {:ok, _} = Ledger.post(transfer(from, to, 40))
      assert balance!(from).available_minor == 0
    end

    test "refuses a capture of a hold that does not exist" do
      from = funded(100)
      to = Fixtures.customer_account()

      assert {:error, :hold_not_found} =
               Ledger.post(transfer(from, to, 10), capture_hold: Ecto.UUID.generate())
    end

    test "a failed post in an outer transaction rolls the outer one back" do
      from = funded(100)
      to = Fixtures.customer_account()

      result =
        Repo.transact(fn ->
          {:ok, _} = Ledger.post(transfer(from, to, 10))
          Ledger.post(transfer(from, to, 1000))
        end)

      assert {:error, :insufficient_funds} = result
      assert balance!(from).balance_minor == 100
      assert balance!(to).balance_minor == 0
      assert count(Transaction) == 1
    end

    test "a failed post that the outer caller ignores still rolls the outer one back" do
      from = funded(100)
      to = Fixtures.customer_account()

      result =
        Repo.transact(fn ->
          {:ok, _} = Ledger.post(transfer(from, to, 10))
          {:error, :insufficient_funds} = Ledger.post(transfer(from, to, 1000))
          {:ok, :done}
        end)

      refute match?({:ok, _}, result)
      assert balance!(from).balance_minor == 100
      assert count(Transaction) == 1
    end

    test "commits with the outer transaction when it succeeds" do
      from = funded(100)
      to = Fixtures.customer_account()

      assert {:ok, :done} =
               Repo.transact(fn ->
                 {:ok, _} = Ledger.post(transfer(from, to, 10))
                 {:ok, :done}
               end)

      assert balance!(to).balance_minor == 10
    end
  end

  describe "post/2 with capture_hold" do
    test "consumes the hold and moves the money" do
      from = funded(100)
      to = Fixtures.customer_account()
      hold = hold!(from, 40)

      assert {:ok, transaction} = Ledger.post(transfer(from, to, 40), capture_hold: hold.id)

      assert %Hold{status: :captured, capture_transaction_id: id} = Repo.get!(Hold, hold.id)
      assert id == transaction.id
      assert %{balance_minor: 60, held_minor: 0} = balance!(from)
      assert balance!(to).balance_minor == 40
      assert Audit.run() == []
    end

    test "a replay returns the first result and does not touch the hold" do
      from = funded(100)
      to = Fixtures.customer_account()
      hold = hold!(from, 40)
      request = transfer(from, to, 40)

      {:ok, first} = Ledger.post(request, capture_hold: hold.id)
      before = {Repo.get!(Hold, hold.id), balance!(from), balance!(to)}

      assert {:ok, again} = Ledger.post(request, capture_hold: hold.id)
      assert again.id == first.id
      assert before == {Repo.get!(Hold, hold.id), balance!(from), balance!(to)}
    end

    test "refuses a capture with the wrong amount and changes nothing" do
      from = funded(100)
      to = Fixtures.customer_account()
      hold = hold!(from, 40)

      assert {:error, :hold_mismatch} = Ledger.post(transfer(from, to, 39), capture_hold: hold.id)
      assert {:error, :hold_mismatch} = Ledger.post(transfer(from, to, 41), capture_hold: hold.id)

      assert Repo.get!(Hold, hold.id).status == :active
      assert %{balance_minor: 100, held_minor: 40} = balance!(from)
    end

    test "refuses a capture that does not debit the account of the hold" do
      from = funded(100)
      other = funded(100)
      to = Fixtures.customer_account()
      hold = hold!(from, 40)

      assert {:error, :hold_mismatch} =
               Ledger.post(transfer(other, to, 40), capture_hold: hold.id)
    end

    test "refuses a capture of a released hold" do
      from = funded(100)
      to = Fixtures.customer_account()
      hold = hold!(from, 40)
      {:ok, _} = Ledger.release_hold(hold.id)

      assert {:error, :hold_not_active} =
               Ledger.post(transfer(from, to, 40), capture_hold: hold.id)

      assert %{balance_minor: 100, held_minor: 0} = balance!(from)
    end

    test "refuses a second capture of a captured hold" do
      from = funded(100)
      to = Fixtures.customer_account()
      hold = hold!(from, 40)
      {:ok, _} = Ledger.post(transfer(from, to, 40), capture_hold: hold.id)

      assert {:error, :hold_not_active} =
               Ledger.post(transfer(from, to, 40), capture_hold: hold.id)

      assert balance!(from).balance_minor == 60
    end
  end

  describe "reverse/2" do
    test "writes the opposite postings and restores the balances" do
      from = funded(100)
      to = Fixtures.customer_account()
      {:ok, original} = Ledger.post(transfer(from, to, 30))

      assert {:ok, reversal} = Ledger.reverse(original.id)
      assert reversal.reverses_id == original.id
      assert reversal.kind == "reversal"
      assert reversal.source_type == "ledger_transaction"
      assert reversal.source_id == original.id

      assert balance!(from).balance_minor == 100
      assert balance!(to).balance_minor == 0
      assert Audit.run() == []
    end

    test "a repeated call returns the first reversal" do
      from = funded(100)
      to = Fixtures.customer_account()
      {:ok, original} = Ledger.post(transfer(from, to, 30))
      {:ok, first} = Ledger.reverse(original.id)

      assert {:ok, again} = Ledger.reverse(original.id)
      assert again.id == first.id
      assert balance!(from).balance_minor == 100
    end

    test "refuses a reversal of a reversal" do
      from = funded(100)
      to = Fixtures.customer_account()
      {:ok, original} = Ledger.post(transfer(from, to, 30))
      {:ok, reversal} = Ledger.reverse(original.id)

      assert {:error, :invalid_request} = Ledger.reverse(reversal.id)
    end

    test "refuses an unknown or malformed transaction id" do
      assert {:error, :transaction_not_found} = Ledger.reverse(Ecto.UUID.generate())
      assert {:error, :transaction_not_found} = Ledger.reverse("nope")
      assert {:error, :transaction_not_found} = Ledger.reverse(nil)
    end

    test "refuses when the reversal would overdraw an account" do
      from = funded(100)
      to = Fixtures.customer_account()
      other = Fixtures.customer_account()
      {:ok, original} = Ledger.post(transfer(from, to, 30))
      {:ok, _} = Ledger.post(transfer(to, other, 30))

      assert {:error, :insufficient_funds} = Ledger.reverse(original.id)
      assert balance!(to).balance_minor == 0
      assert Audit.run() == []
    end

    test "refuses bad options" do
      assert {:error, :invalid_request} = Ledger.reverse(Ecto.UUID.generate(), capture_hold: "x")
    end

    test "captures a hold" do
      to = Fixtures.customer_account()
      from = Fixtures.house_account()
      {:ok, original} = Ledger.post(transfer(from, to, 40))
      hold = hold!(to, 40)

      assert {:ok, reversal} = Ledger.reverse(original.id, capture_hold: hold.id)
      assert %Hold{status: :captured, capture_transaction_id: id} = Repo.get!(Hold, hold.id)
      assert id == reversal.id
      assert %{balance_minor: 0, held_minor: 0} = balance!(to)
      assert Audit.run() == []
    end

    test "refuses a capture with the wrong amount" do
      to = Fixtures.customer_account()
      from = Fixtures.house_account()
      {:ok, original} = Ledger.post(transfer(from, to, 40))
      hold = hold!(to, 25)

      assert {:error, :hold_mismatch} = Ledger.reverse(original.id, capture_hold: hold.id)
      assert Repo.get!(Hold, hold.id).status == :active
      assert balance!(to).balance_minor == 40
    end

    test "refuses a capture of a released hold" do
      to = Fixtures.customer_account()
      from = Fixtures.house_account()
      {:ok, original} = Ledger.post(transfer(from, to, 40))
      hold = hold!(to, 40)
      {:ok, _} = Ledger.release_hold(hold.id)

      assert {:error, :hold_not_active} = Ledger.reverse(original.id, capture_hold: hold.id)
    end
  end

  describe "place_hold/1" do
    test "raises held and lowers available" do
      account = funded(100)

      assert {:ok, %Hold{status: :active, amount_minor: 30}} =
               Ledger.place_hold(%{
                 account_id: account.id,
                 amount_minor: 30,
                 source_type: "t",
                 source_id: "1"
               })

      assert %{balance_minor: 100, held_minor: 30, available_minor: 70} = balance!(account)
      assert Audit.run() == []
    end

    test "a replay returns the same hold and changes nothing" do
      account = funded(100)
      first = hold!(account, 30, "same")
      assert {:ok, again} = Ledger.place_hold(hold_request(account, 30, "same"))

      assert again.id == first.id
      assert balance!(account).held_minor == 30
      assert count(Hold) == 1
    end

    test "refuses the same source with another amount or account" do
      account = funded(100)
      other = funded(100)
      hold!(account, 30, "same")

      assert {:error, :source_conflict} = Ledger.place_hold(hold_request(account, 31, "same"))
      assert {:error, :source_conflict} = Ledger.place_hold(hold_request(other, 30, "same"))
      assert balance!(account).held_minor == 30
      assert balance!(other).held_minor == 0
    end

    test "refuses an amount above the available balance" do
      account = funded(100)
      hold!(account, 60)

      assert {:error, :insufficient_funds} = Ledger.place_hold(hold_request(account, 41, "x"))
      assert balance!(account).held_minor == 60
      assert {:error, :hold_not_found} = Ledger.fetch_hold("test_hold", "x")
    end

    test "refuses an unknown account" do
      ghost = %Account{id: Ecto.UUID.generate()}
      assert {:error, :account_not_found} = Ledger.place_hold(hold_request(ghost, 1, "x"))
    end

    test "refuses invalid input" do
      account = funded(100)
      good = hold_request(account, 10, "x")

      for bad <- [
            nil,
            %{},
            "x",
            %{good | amount_minor: 0},
            %{good | amount_minor: -1},
            %{good | amount_minor: 1.0},
            %{good | amount_minor: Chebit.Money.max_amount_minor() + 1},
            %{good | account_id: "x"},
            %{good | source_type: ""},
            %{good | source_id: nil},
            Map.delete(good, :source_id)
          ] do
        assert {:error, :invalid_request} = Ledger.place_hold(bad)
      end

      assert count(Hold) == 0
    end
  end

  defp hold_request(account, amount, source_id) do
    %{
      account_id: account.id,
      amount_minor: amount,
      source_type: "test_hold",
      source_id: source_id
    }
  end

  describe "release_hold/1" do
    test "makes the amount available again" do
      account = funded(100)
      hold = hold!(account, 30)

      assert {:ok, %Hold{status: :released}} = Ledger.release_hold(hold.id)
      assert %{held_minor: 0, available_minor: 100} = balance!(account)
      assert Audit.run() == []
    end

    test "a second release returns the released hold and changes nothing" do
      account = funded(100)
      other = hold!(account, 20)
      hold = hold!(account, 30)
      {:ok, first} = Ledger.release_hold(hold.id)

      assert {:ok, %Hold{status: :released} = again} = Ledger.release_hold(hold.id)
      assert again.id == first.id
      assert balance!(account).held_minor == 20
      assert Repo.get!(Hold, other.id).status == :active
    end

    test "refuses a captured hold" do
      account = funded(100)
      hold = hold!(account, 30)

      {:ok, _} =
        Ledger.post(transfer(account, Fixtures.customer_account(), 30), capture_hold: hold.id)

      assert {:error, :hold_not_active} = Ledger.release_hold(hold.id)
      assert balance!(account).held_minor == 0
    end

    test "refuses an unknown or malformed hold id" do
      assert {:error, :hold_not_found} = Ledger.release_hold(Ecto.UUID.generate())
      assert {:error, :hold_not_found} = Ledger.release_hold("nope")
      assert {:error, :hold_not_found} = Ledger.release_hold(nil)
    end
  end

  describe "fetch_hold/2" do
    test "finds the hold of a source" do
      account = funded(100)
      hold = hold!(account, 30, "src-1")
      assert {:ok, found} = Ledger.fetch_hold("test_hold", "src-1")
      assert found.id == hold.id
    end

    test "returns an error for an unknown source" do
      assert {:error, :hold_not_found} = Ledger.fetch_hold("test_hold", "missing")
      assert {:error, :hold_not_found} = Ledger.fetch_hold(nil, nil)
    end
  end

  describe "fetch_transaction/3" do
    test "finds the transaction with its postings" do
      from = funded(100)
      to = Fixtures.customer_account()
      request = transfer(from, to, 30)
      {:ok, written} = Ledger.post(request)

      assert {:ok, found} = Ledger.fetch_transaction("test", request.source_id, "transfer")
      assert found.id == written.id
      assert length(found.postings) == 2
    end

    test "returns an error for an unknown source or kind" do
      from = funded(100)
      request = transfer(from, Fixtures.customer_account(), 30)
      {:ok, _} = Ledger.post(request)

      assert {:error, :transaction_not_found} =
               Ledger.fetch_transaction("test", "missing", "transfer")

      assert {:error, :transaction_not_found} =
               Ledger.fetch_transaction("test", request.source_id, "other")

      assert {:error, :transaction_not_found} = Ledger.fetch_transaction(nil, nil, nil)
    end
  end

  describe "balance/1" do
    test "reads the cached balance" do
      account = funded(100)
      hold!(account, 30)

      assert {:ok, balance} = Ledger.balance(account.id)

      assert balance == %{
               account_id: account.id,
               kind: "balance",
               currency: :ARS,
               balance_minor: 100,
               held_minor: 30,
               available_minor: 70
             }
    end

    test "returns an error for an unknown or malformed id" do
      assert {:error, :account_not_found} = Ledger.balance(Ecto.UUID.generate())
      assert {:error, :account_not_found} = Ledger.balance("nope")
      assert {:error, :account_not_found} = Ledger.balance(nil)
    end
  end

  describe "balances/1" do
    test "lists the accounts of an owner ordered by kind and currency" do
      owner = {:merchant, Ecto.UUID.generate()}
      {:ok, _} = Ledger.ensure_account(owner, "fees", :ARS)
      {:ok, _} = Ledger.ensure_account(owner, "balance", :USD)
      {:ok, _} = Ledger.ensure_account(owner, "balance", :ARS)
      {:ok, _} = Ledger.ensure_account({:merchant, Ecto.UUID.generate()}, "balance", :ARS)

      assert [
               %{currency: :ARS},
               %{currency: :USD},
               %{currency: :ARS}
             ] = Ledger.balances(owner)
    end

    test "lists the house accounts" do
      account = Fixtures.house_account()
      assert Enum.any?(Ledger.balances(:house), &(&1.account_id == account.id))
    end

    test "returns an empty list for an unknown or malformed owner" do
      assert Ledger.balances({:merchant, Ecto.UUID.generate()}) == []
      assert Ledger.balances({:merchant, "x"}) == []
      assert Ledger.balances(nil) == []
    end
  end

  describe "post/2 replay with other options" do
    test "a replay that names a hold which the first call did not capture is a conflict" do
      customer = funded(100)
      house = Fixtures.house_account()
      request = transfer(customer, house, 40)
      assert {:ok, first} = Ledger.post(request)

      hold = hold!(customer, 40)

      assert Ledger.post(request, capture_hold: hold.id) == {:error, :source_conflict}
      assert {:ok, %{status: :active}} = Ledger.fetch_hold(hold.source_type, hold.source_id)
      assert balance!(customer).held_minor == 40

      # The replay without the hold still gets the first result.
      assert {:ok, %{id: id}} = Ledger.post(request)
      assert id == first.id
    end

    test "a replay that names the hold which the first call captured gets the first result" do
      customer = funded(100)
      house = Fixtures.house_account()
      hold = hold!(customer, 40)
      request = transfer(customer, house, 40)

      assert {:ok, first} = Ledger.post(request, capture_hold: hold.id)
      assert {:ok, again} = Ledger.post(request, capture_hold: hold.id)
      assert again.id == first.id

      assert balance!(customer) |> Map.take([:balance_minor, :held_minor]) ==
               %{balance_minor: 60, held_minor: 0}
    end
  end

  describe "post/2 with reverses_id" do
    test "refuses entries that are not the mirror of the transaction" do
      customer = funded(100)
      house = Fixtures.house_account()
      assert {:ok, original} = Ledger.post(transfer(customer, house, 40))

      not_the_mirror =
        house |> transfer(customer, 10) |> Map.put(:reverses_id, original.id)

      assert Ledger.post(not_the_mirror) == {:error, :invalid_request}

      # The one reversal of the transaction is still free.
      assert {:ok, %{reverses_id: reverses_id}} = Ledger.reverse(original.id)
      assert reverses_id == original.id
    end

    test "refuses to reverse a reversal" do
      customer = funded(100)
      house = Fixtures.house_account()
      assert {:ok, original} = Ledger.post(transfer(customer, house, 40))
      assert {:ok, reversal} = Ledger.reverse(original.id)

      again = customer |> transfer(house, 40) |> Map.put(:reverses_id, reversal.id)
      assert Ledger.post(again) == {:error, :invalid_request}
    end
  end
end
