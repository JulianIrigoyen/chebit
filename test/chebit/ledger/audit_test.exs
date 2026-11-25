defmodule Chebit.Ledger.AuditTest do
  use Chebit.DataCase, async: true

  alias Chebit.Fixtures
  alias Chebit.Ledger
  alias Chebit.Ledger.Audit

  # Each test corrupts rows with raw SQL, so it fixes the state that the checks read.
  # Sandbox isolation makes the global check `:currency_not_zero` see only these rows.

  defp sql!(sql, params \\ []), do: Repo.query!(sql, params)

  defp uuid_param(id), do: Ecto.UUID.dump!(id)

  defp checks(violations), do: violations |> Enum.map(& &1.check) |> Enum.uniq() |> Enum.sort()

  describe "run/0" do
    test "returns an empty list for an empty ledger" do
      assert Audit.run() == []
    end

    test "returns an empty list for a clean ledger with holds and reversals" do
      a = Fixtures.customer_account()
      b = Fixtures.customer_account()
      tx = Fixtures.fund(a, 100)
      {:ok, _} = Ledger.reverse(tx.id)
      Fixtures.fund(a, 100)

      {:ok, _} =
        Ledger.post(%{
          kind: "transfer",
          source_type: "test",
          source_id: "1",
          entries: [
            %{account_id: a.id, direction: :debit, amount_minor: 30, currency: :ARS},
            %{account_id: b.id, direction: :credit, amount_minor: 30, currency: :ARS}
          ]
        })

      {:ok, _} =
        Ledger.place_hold(%{account_id: a.id, amount_minor: 20, source_type: "h", source_id: "1"})

      assert Audit.run() == []
    end

    test "reports :balance_cache_mismatch for a cache that differs from the postings" do
      account = Fixtures.customer_account()
      Fixtures.fund(account, 100)

      # Move 10 from the customer to a house account, so the currency still sums to zero.
      house = Ledger.balances(:house) |> Enum.find(&(&1.balance_minor == -100))
      sql!("UPDATE accounts SET balance_minor = 90 WHERE id = $1", [uuid_param(account.id)])

      sql!("UPDATE accounts SET balance_minor = -90 WHERE id = $1", [uuid_param(house.account_id)])

      violations = Audit.run()
      assert checks(violations) == [:balance_cache_mismatch]

      assert Enum.sort(Enum.map(violations, & &1.subject)) ==
               Enum.sort([account.id, house.account_id])

      assert %{detail: %{cached_minor: 90, postings_minor: 100}} =
               Enum.find(violations, &(&1.subject == account.id))
    end

    test "reports :held_cache_mismatch for a cache that differs from the active holds" do
      account = Fixtures.customer_account()
      Fixtures.fund(account, 100)
      sql!("UPDATE accounts SET held_minor = 30 WHERE id = $1", [uuid_param(account.id)])

      assert [%{check: :held_cache_mismatch, subject: subject, detail: detail}] = Audit.run()
      assert subject == account.id
      assert detail == %{cached_minor: 30, active_holds_minor: 0}
    end

    test "does not count a released hold as held" do
      account = Fixtures.customer_account()
      Fixtures.fund(account, 100)

      {:ok, hold} =
        Ledger.place_hold(%{
          account_id: account.id,
          amount_minor: 30,
          source_type: "h",
          source_id: "1"
        })

      {:ok, _} = Ledger.release_hold(hold.id)
      assert Audit.run() == []

      # A released hold is terminal, so a cache above zero has no hold behind it.
      sql!("UPDATE accounts SET held_minor = 30 WHERE id = $1", [uuid_param(account.id)])
      assert checks(Audit.run()) == [:held_cache_mismatch]
    end

    test "does not report a negative house account" do
      house = Fixtures.house_account()
      Fixtures.fund(Fixtures.customer_account(), 100)
      assert {:ok, %{balance_minor: _}} = Ledger.balance(house.id)
      assert Audit.run() == []
    end

    test "reports :transaction_unbalanced for a transaction that does not sum to zero" do
      # Two unbalanced transactions that cancel: the caches match the postings and the
      # currency sums to zero, so only this check fires. The trigger refuses the insert,
      # so the test turns triggers off for this transaction (replica role).
      h1 = Fixtures.house_account()
      h2 = Fixtures.house_account()
      t1 = Ecto.UUID.generate()
      t2 = Ecto.UUID.generate()

      for {id, n} <- [{t1, "1"}, {t2, "2"}] do
        sql!(
          "INSERT INTO ledger_transactions (id, kind, source_type, source_id, inserted_at) VALUES ($1, 'raw', 'raw', $2, now())",
          [uuid_param(id), n]
        )
      end

      sql!("SET LOCAL session_replication_role = replica")

      for {tx, account, direction} <- [{t1, h1, "credit"}, {t2, h2, "debit"}] do
        sql!(
          "INSERT INTO postings (transaction_id, currency, account_id, direction, amount_minor, inserted_at) VALUES ($1, 'ARS', $2, $3, 5, now())",
          [uuid_param(tx), uuid_param(account.id), direction]
        )
      end

      sql!("UPDATE accounts SET balance_minor = 5 WHERE id = $1", [uuid_param(h1.id)])
      sql!("UPDATE accounts SET balance_minor = -5 WHERE id = $1", [uuid_param(h2.id)])

      violations = Audit.run()
      assert checks(violations) == [:transaction_unbalanced]
      assert Enum.sort(Enum.map(violations, & &1.subject)) == Enum.sort([t1, t2])

      assert %{detail: %{currency: "ARS", debits_minus_credits_minor: -5}} =
               Enum.find(violations, &(&1.subject == t1))
    end

    test "reports :currency_not_zero when money appears in a currency" do
      # A cache that changes alone also breaks the cache check: the postings of a
      # balanced ledger always sum to zero, so a nonzero total cannot occur without one.
      house = Fixtures.house_account(:USD)
      sql!("UPDATE accounts SET balance_minor = 7 WHERE id = $1", [uuid_param(house.id)])

      violations = Audit.run()

      assert %{subject: "USD", detail: %{sum_minor: 7}} =
               Enum.find(violations, &(&1.check == :currency_not_zero))

      assert checks(violations) == [:balance_cache_mismatch, :currency_not_zero]
      assert Enum.count(violations, &(&1.check == :currency_not_zero)) == 1
    end
  end
end
