defmodule Chebit.Ledger.DbConstraintsTest do
  @moduledoc """
  Each test bypasses the application with raw SQL and proves that the database refuses.
  A failed statement outside `Repo.transact` does not poison the sandbox transaction.
  """
  use Chebit.DataCase, async: true

  alias Chebit.Fixtures
  alias Chebit.Ledger

  defp dump(id), do: Ecto.UUID.dump!(id)

  # Runs the statement and asserts that Postgres refuses it with `constraint`.
  defp assert_refused(sql, params, constraint) do
    assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint, code: code}}} =
             Repo.query(sql, params)

    assert code in [:check_violation, :foreign_key_violation]
  end

  defp new_transaction do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO ledger_transactions (id, kind, source_type, source_id, inserted_at) VALUES ($1, 'raw', 'raw', $2, now())",
      [dump(id), id]
    )

    id
  end

  @insert_posting "INSERT INTO postings (transaction_id, currency, account_id, direction, amount_minor, inserted_at)"

  setup do
    customer = Fixtures.customer_account()
    other = Fixtures.customer_account()
    Fixtures.fund(customer, 100)
    %{customer: customer, other: other}
  end

  test "postings_balanced refuses an unbalanced INSERT of postings", %{customer: c, other: o} do
    tx = new_transaction()

    assert_refused(
      "#{@insert_posting} VALUES ($1, 'ARS', $2, 'debit', 10, now()), ($1, 'ARS', $3, 'credit', 9, now())",
      [dump(tx), dump(c.id), dump(o.id)],
      "postings_balanced"
    )

    assert Repo.query!("SELECT count(*) FROM postings WHERE transaction_id = $1", [dump(tx)]).rows ==
             [[0]]
  end

  test "postings_balanced refuses a single posting", %{customer: c} do
    tx = new_transaction()

    assert_refused(
      "#{@insert_posting} VALUES ($1, 'ARS', $2, 'credit', 10, now())",
      [dump(tx), dump(c.id)],
      "postings_balanced"
    )
  end

  test "postings_balanced refuses postings that balance only across currencies", %{customer: c} do
    usd = Fixtures.customer_account(:USD)
    tx = new_transaction()

    assert_refused(
      "#{@insert_posting} VALUES ($1, 'ARS', $2, 'debit', 10, now()), ($1, 'USD', $3, 'credit', 10, now())",
      [dump(tx), dump(c.id), dump(usd.id)],
      "postings_balanced"
    )
  end

  test "postings_append_only refuses UPDATE and DELETE on postings" do
    assert_refused(
      "UPDATE postings SET amount_minor = amount_minor + 1",
      [],
      "postings_append_only"
    )

    assert_refused("DELETE FROM postings", [], "postings_append_only")
  end

  test "ledger_transactions_append_only refuses UPDATE and DELETE on ledger_transactions" do
    assert_refused(
      "UPDATE ledger_transactions SET kind = 'x'",
      [],
      "ledger_transactions_append_only"
    )

    assert_refused("DELETE FROM ledger_transactions", [], "ledger_transactions_append_only")
  end

  test "postings_account_id_fkey refuses a posting whose currency differs from its account",
       %{customer: c, other: o} do
    tx = new_transaction()

    # The two postings balance in USD, so only the currency of the accounts is wrong.
    assert_refused(
      "#{@insert_posting} VALUES ($1, 'USD', $2, 'debit', 10, now()), ($1, 'USD', $3, 'credit', 10, now())",
      [dump(tx), dump(c.id), dump(o.id)],
      "postings_account_id_fkey"
    )
  end

  test "accounts_available_non_negative refuses held_minor above the balance", %{customer: c} do
    assert_refused(
      "UPDATE accounts SET held_minor = 101 WHERE id = $1",
      [dump(c.id)],
      "accounts_available_non_negative"
    )

    assert {:ok, %{held_minor: 0}} = Ledger.balance(c.id)
  end

  test "accounts_available_non_negative refuses a balance below the held amount", %{customer: c} do
    {:ok, _} =
      Ledger.place_hold(%{account_id: c.id, amount_minor: 60, source_type: "h", source_id: "1"})

    assert_refused(
      "UPDATE accounts SET balance_minor = 59 WHERE id = $1",
      [dump(c.id)],
      "accounts_available_non_negative"
    )
  end

  test "accounts_available_non_negative refuses a negative merchant balance", %{customer: c} do
    assert_refused(
      "UPDATE accounts SET balance_minor = -1 WHERE id = $1",
      [dump(c.id)],
      "accounts_available_non_negative"
    )
  end

  test "accounts_held_non_negative refuses a negative held_minor", %{customer: c} do
    assert_refused(
      "UPDATE accounts SET held_minor = -1 WHERE id = $1",
      [dump(c.id)],
      "accounts_held_non_negative"
    )
  end

  test "postings_amount_positive refuses an amount_minor of 0", %{customer: c, other: o} do
    tx = new_transaction()

    assert_refused(
      "#{@insert_posting} VALUES ($1, 'ARS', $2, 'debit', 0, now()), ($1, 'ARS', $3, 'credit', 0, now())",
      [dump(tx), dump(c.id), dump(o.id)],
      "postings_amount_positive"
    )
  end

  test "postings_amount_positive refuses a negative amount_minor", %{customer: c, other: o} do
    tx = new_transaction()

    assert_refused(
      "#{@insert_posting} VALUES ($1, 'ARS', $2, 'debit', -5, now()), ($1, 'ARS', $3, 'credit', -5, now())",
      [dump(tx), dump(c.id), dump(o.id)],
      "postings_amount_positive"
    )
  end

  describe "holds_terminal_status" do
    setup %{customer: c, other: o} do
      {:ok, captured} =
        Ledger.place_hold(%{account_id: c.id, amount_minor: 10, source_type: "h", source_id: "c"})

      {:ok, _} =
        Ledger.post(
          %{
            kind: "capture",
            source_type: "t",
            source_id: "c",
            entries: [
              %{account_id: c.id, direction: :debit, amount_minor: 10, currency: :ARS},
              %{account_id: o.id, direction: :credit, amount_minor: 10, currency: :ARS}
            ]
          },
          capture_hold: captured.id
        )

      {:ok, released} =
        Ledger.place_hold(%{account_id: c.id, amount_minor: 10, source_type: "h", source_id: "r"})

      {:ok, _} = Ledger.release_hold(released.id)
      %{captured: captured, released: released}
    end

    test "refuses to change the status of a captured hold", %{captured: hold} do
      for status <- ["active", "released"] do
        assert_refused(
          "UPDATE holds SET status = $2 WHERE id = $1",
          [dump(hold.id), status],
          "holds_terminal_status"
        )
      end
    end

    test "refuses to change the status of a released hold", %{released: hold} do
      assert_refused(
        "UPDATE holds SET status = 'active' WHERE id = $1",
        [dump(hold.id)],
        "holds_terminal_status"
      )
    end
  end

  test "holds_capture_has_transaction refuses a captured hold without a transaction", %{
    customer: c
  } do
    {:ok, hold} =
      Ledger.place_hold(%{account_id: c.id, amount_minor: 10, source_type: "h", source_id: "1"})

    assert_refused(
      "UPDATE holds SET status = 'captured' WHERE id = $1",
      [dump(hold.id)],
      "holds_capture_has_transaction"
    )
  end

  test "the unique index refuses a second transaction for one source", %{customer: c} do
    sql =
      "INSERT INTO ledger_transactions (id, kind, source_type, source_id, inserted_at) VALUES ($1, 'k', 's', 'same', now())"

    Repo.query!(sql, [dump(Ecto.UUID.generate())])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, [dump(Ecto.UUID.generate())])

    assert {:ok, _} = Ledger.balance(c.id)
  end
end
