defmodule Chebit.Ledger.RulesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chebit.Ledger.Account
  alias Chebit.Ledger.Hold
  alias Chebit.Ledger.Posting
  alias Chebit.Ledger.Rules

  @a Ecto.UUID.generate()
  @b Ecto.UUID.generate()
  @c Ecto.UUID.generate()

  defp entry(account_id, direction, amount, currency \\ :ARS) do
    %{account_id: account_id, direction: direction, amount_minor: amount, currency: currency}
  end

  defp request(entries) do
    %{kind: "payment", source_type: "intent", source_id: "i-1", entries: entries}
  end

  defp account(id, owner_type, balance, opts \\ []) do
    %Account{
      id: id,
      owner_type: owner_type,
      currency: Keyword.get(opts, :currency, :ARS),
      balance_minor: balance,
      held_minor: Keyword.get(opts, :held, 0)
    }
  end

  defp hold(account_id, amount, status \\ :active) do
    %Hold{id: Ecto.UUID.generate(), account_id: account_id, amount_minor: amount, status: status}
  end

  defp posting(entry), do: struct!(Posting, entry)

  describe "validate/1" do
    test "accepts a balanced request" do
      assert :ok = Rules.validate(request([entry(@a, :debit, 10), entry(@b, :credit, 10)]))
    end

    test "accepts optional metadata and reverses_id" do
      req =
        request([entry(@a, :debit, 10), entry(@b, :credit, 10)])
        |> Map.merge(%{metadata: %{"a" => 1}, reverses_id: Ecto.UUID.generate()})

      assert :ok = Rules.validate(req)
    end

    test "accepts a split entry that balances in total" do
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 4), entry(@c, :credit, 6)]
      assert :ok = Rules.validate(request(entries))
    end

    test "balances each currency on its own" do
      entries = [
        entry(@a, :debit, 10, :ARS),
        entry(@b, :credit, 10, :ARS),
        entry(@b, :debit, 5, :USD),
        entry(@c, :credit, 5, :USD)
      ]

      assert :ok = Rules.validate(request(entries))
    end

    test "refuses debits and credits that differ" do
      assert {:error, :unbalanced} =
               Rules.validate(request([entry(@a, :debit, 10), entry(@b, :credit, 9)]))
    end

    test "refuses a balance that holds only across currencies" do
      entries = [entry(@a, :debit, 10, :ARS), entry(@b, :credit, 10, :USD)]
      assert {:error, :unbalanced} = Rules.validate(request(entries))
    end

    test "accepts the largest bigint amount" do
      max = Chebit.Money.max_amount_minor()
      assert :ok = Rules.validate(request([entry(@a, :debit, max), entry(@b, :credit, max)]))
    end
  end

  describe "validate/1 rejected input" do
    setup do
      %{good: request([entry(@a, :debit, 10), entry(@b, :credit, 10)])}
    end

    test "refuses a request that is not a map" do
      for bad <- [nil, [], "x", 1, 1.5, :atom, {:a, 1}, [entry(@a, :debit, 1)]] do
        assert {:error, :invalid_request} = Rules.validate(bad)
      end
    end

    test "refuses a missing or empty string field", %{good: good} do
      for key <- [:kind, :source_type, :source_id] do
        assert {:error, :invalid_request} = Rules.validate(Map.delete(good, key))
        assert {:error, :invalid_request} = Rules.validate(Map.put(good, key, ""))
        assert {:error, :invalid_request} = Rules.validate(Map.put(good, key, :atom))
        assert {:error, :invalid_request} = Rules.validate(Map.put(good, key, 12))
      end
    end

    test "refuses missing entries and fewer than two", %{good: good} do
      assert {:error, :invalid_request} = Rules.validate(Map.delete(good, :entries))
      assert {:error, :invalid_request} = Rules.validate(%{good | entries: []})

      assert {:error, :invalid_request} =
               Rules.validate(%{good | entries: [entry(@a, :debit, 1)]})

      assert {:error, :invalid_request} = Rules.validate(%{good | entries: :nope})
      assert {:error, :invalid_request} = Rules.validate(%{good | entries: %{}})
    end

    test "refuses an improper list of entries", %{good: good} do
      assert {:error, :invalid_request} =
               Rules.validate(%{good | entries: [entry(@a, :debit, 1) | entry(@b, :credit, 1)]})
    end

    test "refuses a float amount" do
      assert {:error, :invalid_request} =
               Rules.validate(request([entry(@a, :debit, 10.0), entry(@b, :credit, 10.0)]))
    end

    test "refuses a Decimal-like struct amount" do
      decimal = %{__struct__: Decimal, sign: 1, coef: 10, exp: 0}

      assert {:error, :invalid_request} =
               Rules.validate(request([entry(@a, :debit, decimal), entry(@b, :credit, decimal)]))
    end

    test "refuses a numeric string amount" do
      assert {:error, :invalid_request} =
               Rules.validate(request([entry(@a, :debit, "10"), entry(@b, :credit, "10")]))
    end

    test "refuses a zero amount" do
      assert {:error, :invalid_request} =
               Rules.validate(request([entry(@a, :debit, 0), entry(@b, :credit, 0)]))
    end

    test "refuses a negative amount" do
      assert {:error, :invalid_request} =
               Rules.validate(request([entry(@a, :debit, -10), entry(@b, :credit, -10)]))
    end

    test "refuses an amount above bigint" do
      big = Chebit.Money.max_amount_minor() + 1

      assert {:error, :invalid_request} =
               Rules.validate(request([entry(@a, :debit, big), entry(@b, :credit, big)]))
    end

    test "refuses a bad account id", %{good: good} do
      for bad <- [nil, "x", 1, String.upcase(@a), :crypto.strong_rand_bytes(16)] do
        entries = [entry(bad, :debit, 10), entry(@b, :credit, 10)]
        assert {:error, :invalid_request} = Rules.validate(%{good | entries: entries})
      end
    end

    test "refuses a bad direction", %{good: good} do
      for bad <- [nil, :up, "debit", 1] do
        entries = [entry(@a, bad, 10), entry(@b, :credit, 10)]
        assert {:error, :invalid_request} = Rules.validate(%{good | entries: entries})
      end
    end

    test "refuses a bad currency", %{good: good} do
      for bad <- [nil, :EUR, "ARS", 1] do
        entries = [entry(@a, :debit, 10, bad), entry(@b, :credit, 10, bad)]
        assert {:error, :invalid_request} = Rules.validate(%{good | entries: entries})
      end
    end

    test "refuses an entry that is not a map or lacks a key", %{good: good} do
      assert {:error, :invalid_request} =
               Rules.validate(%{good | entries: [:x, entry(@b, :credit, 10)]})

      assert {:error, :invalid_request} =
               Rules.validate(%{
                 good
                 | entries: [Map.delete(entry(@a, :debit, 10), :currency), entry(@b, :credit, 10)]
               })
    end

    test "refuses bad metadata and bad reverses_id", %{good: good} do
      assert {:error, :invalid_request} = Rules.validate(Map.put(good, :metadata, "x"))
      assert {:error, :invalid_request} = Rules.validate(Map.put(good, :reverses_id, "x"))
    end
  end

  describe "apply_entries/3" do
    test "credits raise and debits lower the balance" do
      accounts = [account(@a, :house, 0), account(@b, :merchant, 5)]
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]

      assert {:ok, changes} = Rules.apply_entries(accounts, entries, nil)

      assert changes == %{
               @a => %{balance_delta_minor: -10, held_delta_minor: 0},
               @b => %{balance_delta_minor: 10, held_delta_minor: 0}
             }
    end

    test "sums several entries on one account" do
      accounts = [account(@a, :house, 0), account(@b, :user, 0)]
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 4), entry(@b, :credit, 6)]

      assert {:ok, %{@b => %{balance_delta_minor: 10}}} =
               Rules.apply_entries(accounts, entries, nil)
    end

    test "refuses an unknown account" do
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]

      assert {:error, :account_not_found} =
               Rules.apply_entries([account(@a, :house, 0)], entries, nil)
    end

    test "refuses a currency that differs from the account" do
      accounts = [account(@a, :house, 0), account(@b, :merchant, 0, currency: :USD)]
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]
      assert {:error, :currency_mismatch} = Rules.apply_entries(accounts, entries, nil)
    end

    test "refuses a debit below zero on a merchant or user account" do
      for type <- [:merchant, :user] do
        accounts = [account(@a, type, 9), account(@b, :house, 0)]
        entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]
        assert {:error, :insufficient_funds} = Rules.apply_entries(accounts, entries, nil)
      end
    end

    test "refuses a balance that leaves the bigint range, in either direction" do
      max = Chebit.Money.max_amount_minor()

      credited = [account(@a, :house, 0), account(@b, :merchant, max)]
      entries = [entry(@a, :debit, 1), entry(@b, :credit, 1)]
      assert {:error, :balance_out_of_range} = Rules.apply_entries(credited, entries, nil)

      debited = [account(@a, :house, -max), account(@b, :merchant, 0)]
      assert {:error, :balance_out_of_range} = Rules.apply_entries(debited, entries, nil)

      at_the_limit = [account(@a, :house, -(max - 1)), account(@b, :merchant, max - 1)]
      assert {:ok, _changes} = Rules.apply_entries(at_the_limit, entries, nil)
    end

    test "a debit that a credit on the same account cancels does not capture a hold" do
      accounts = [account(@a, :merchant, 1000, held: 1000), account(@b, :house, 0)]
      held = hold(@a, 1000)

      washed = [
        entry(@a, :debit, 1000),
        entry(@a, :credit, 1000),
        entry(@b, :debit, 5),
        entry(@b, :credit, 5)
      ]

      assert {:error, :hold_mismatch} = Rules.apply_entries(accounts, washed, held)

      partly = [entry(@a, :debit, 1000), entry(@a, :credit, 500), entry(@b, :credit, 500)]
      assert {:error, :hold_mismatch} = Rules.apply_entries(accounts, partly, held)

      real = [entry(@a, :debit, 1000), entry(@b, :credit, 1000)]
      assert {:ok, _changes} = Rules.apply_entries(accounts, real, held)
    end

    test "counts held funds against the available balance" do
      accounts = [account(@a, :merchant, 10, held: 4), account(@b, :house, 0)]

      assert {:error, :insufficient_funds} =
               Rules.apply_entries(accounts, [entry(@a, :debit, 7), entry(@b, :credit, 7)], nil)

      assert {:ok, _} =
               Rules.apply_entries(accounts, [entry(@a, :debit, 6), entry(@b, :credit, 6)], nil)
    end

    test "lets a house account go negative" do
      accounts = [account(@a, :house, 0), account(@b, :merchant, 0)]
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]
      assert {:ok, _} = Rules.apply_entries(accounts, entries, nil)
    end

    test "a capture lowers held by the amount of the hold" do
      accounts = [account(@a, :merchant, 10, held: 10), account(@b, :house, 0)]
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]

      assert {:ok, %{@a => %{balance_delta_minor: -10, held_delta_minor: -10}}} =
               Rules.apply_entries(accounts, entries, hold(@a, 10))
    end

    test "a capture is refused when the hold is not active" do
      accounts = [account(@a, :merchant, 10), account(@b, :house, 0)]
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]

      for status <- [:captured, :released] do
        assert {:error, :hold_not_active} =
                 Rules.apply_entries(accounts, entries, hold(@a, 10, status))
      end
    end

    test "a capture is refused when the debit differs from the hold" do
      accounts = [account(@a, :merchant, 20, held: 10), account(@b, :house, 0)]

      assert {:error, :hold_mismatch} =
               Rules.apply_entries(
                 accounts,
                 [entry(@a, :debit, 9), entry(@b, :credit, 9)],
                 hold(@a, 10)
               )

      assert {:error, :hold_mismatch} =
               Rules.apply_entries(
                 accounts,
                 [entry(@a, :debit, 11), entry(@b, :credit, 11)],
                 hold(@a, 10)
               )

      # The hold account is not debited at all.
      assert {:error, :hold_mismatch} =
               Rules.apply_entries(
                 accounts,
                 [entry(@b, :debit, 10), entry(@a, :credit, 10)],
                 hold(@a, 10)
               )
    end
  end

  describe "same_entries?/2" do
    test "ignores order" do
      entries = [entry(@a, :debit, 10), entry(@b, :credit, 10)]
      postings = entries |> Enum.reverse() |> Enum.map(&posting/1)
      assert Rules.same_entries?(postings, entries)
    end

    test "treats two entries on one account and direction as their sum" do
      postings = [posting(entry(@a, :debit, 10)), posting(entry(@b, :credit, 10))]
      entries = [entry(@a, :debit, 4), entry(@a, :debit, 6), entry(@b, :credit, 10)]
      assert Rules.same_entries?(postings, entries)
    end

    test "differs on amount, direction, account or currency" do
      base = [entry(@a, :debit, 10), entry(@b, :credit, 10)]
      postings = Enum.map(base, &posting/1)

      refute Rules.same_entries?(postings, [entry(@a, :debit, 11), entry(@b, :credit, 11)])
      refute Rules.same_entries?(postings, [entry(@a, :credit, 10), entry(@b, :debit, 10)])
      refute Rules.same_entries?(postings, [entry(@a, :debit, 10), entry(@c, :credit, 10)])

      refute Rules.same_entries?(postings, [
               entry(@a, :debit, 10, :USD),
               entry(@b, :credit, 10, :USD)
             ])

      refute Rules.same_entries?(postings, [entry(@a, :debit, 10)])
    end
  end

  describe "reverses?/2" do
    test "is true only for the exact mirror of the postings" do
      postings = [posting(entry(@a, :debit, 10)), posting(entry(@b, :credit, 10))]

      assert Rules.reverses?(postings, [entry(@b, :debit, 10), entry(@a, :credit, 10)])
      refute Rules.reverses?(postings, [entry(@a, :debit, 10), entry(@b, :credit, 10)])
      refute Rules.reverses?(postings, [entry(@b, :debit, 9), entry(@a, :credit, 9)])
    end
  end

  describe "reversal_entries/1" do
    test "swaps the direction and keeps account, amount and currency" do
      postings = [posting(entry(@a, :debit, 10, :USD)), posting(entry(@b, :credit, 10, :USD))]

      assert Rules.reversal_entries(postings) == [
               entry(@a, :credit, 10, :USD),
               entry(@b, :debit, 10, :USD)
             ]
    end

    test "returns no entries for no postings" do
      assert Rules.reversal_entries([]) == []
    end
  end

  # Generators

  defp amount, do: StreamData.integer(1..1_000_000)

  # One pool of account ids for each currency: an account has one currency.
  @pool Map.new(Chebit.Money.currencies(), fn c ->
          {c, for(_ <- 1..3, do: Ecto.UUID.generate())}
        end)

  defp account_id(currency), do: StreamData.member_of(Map.fetch!(@pool, currency))

  defp currency_entries(currency) do
    gen all amounts <- StreamData.list_of(amount(), min_length: 1, max_length: 4),
            debit_ids <- StreamData.list_of(account_id(currency), length: length(amounts)),
            credit_id <- account_id(currency) do
      debits = for {id, n} <- Enum.zip(debit_ids, amounts), do: entry(id, :debit, n, currency)
      debits ++ [entry(credit_id, :credit, Enum.sum(amounts), currency)]
    end
  end

  defp balanced_entries do
    gen all currencies <-
              StreamData.uniq_list_of(StreamData.member_of(Chebit.Money.currencies()),
                min_length: 1,
                max_length: 3
              ),
            lists <- StreamData.fixed_list(Enum.map(currencies, &currency_entries/1)) do
      lists |> List.flatten() |> Enum.shuffle()
    end
  end

  describe "properties" do
    property "a balanced request validates" do
      check all entries <- balanced_entries(), max_runs: 100 do
        assert :ok = Rules.validate(request(entries))
      end
    end

    property "changing one amount gives :unbalanced" do
      check all entries <- balanced_entries(),
                index <- StreamData.integer(0..(length(entries) - 1)),
                delta <- StreamData.integer(1..1000),
                max_runs: 100 do
        changed = List.update_at(entries, index, &%{&1 | amount_minor: &1.amount_minor + delta})
        assert {:error, :unbalanced} = Rules.validate(request(changed))
      end
    end

    property "reversal_entries applied after the original nets each account to zero" do
      check all entries <- balanced_entries(), max_runs: 100 do
        # Per-currency house accounts have no floor, so both steps apply.
        accounts =
          entries
          |> Enum.uniq_by(& &1.account_id)
          |> Enum.map(&account(&1.account_id, :house, 0, currency: &1.currency))

        assert :ok = Rules.validate(request(entries))
        assert {:ok, forward} = Rules.apply_entries(accounts, entries, nil)

        reversal = entries |> Enum.map(&posting/1) |> Rules.reversal_entries()
        assert {:ok, back} = Rules.apply_entries(accounts, reversal, nil)

        assert Map.keys(forward) == Map.keys(back)

        for {id, change} <- forward do
          assert change.balance_delta_minor + back[id].balance_delta_minor == 0
        end
      end
    end
  end
end
