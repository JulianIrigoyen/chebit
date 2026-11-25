defmodule Chebit.Ledger.AuditSchemaTest do
  # This test drops a constraint. The DDL takes an exclusive lock on `accounts` until its
  # transaction ends, so it must not run next to the async tests: it runs unboxed and alone.
  use Chebit.UnboxedCase

  alias Chebit.Fixtures
  alias Chebit.Ledger.Audit

  defp sql!(sql, params \\ []), do: Repo.query!(sql, params)

  describe "run/0" do
    test "reports :negative_available for a merchant account below zero" do
      # The constraint stops this write. Drop it inside a transaction that rolls back, to
      # prove that the audit sees what the constraint stops.
      Repo.transaction(fn ->
        sql!("ALTER TABLE accounts DROP CONSTRAINT accounts_available_non_negative")

        account = Fixtures.customer_account()
        Fixtures.fund(account, 100)
        account_id = Ecto.UUID.dump!(account.id)

        sql!(
          """
          INSERT INTO holds (id, account_id, amount_minor, status, source_type, source_id, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, 150, 'active', 'raw', '1', now(), now())
          """,
          [account_id]
        )

        sql!("UPDATE accounts SET held_minor = 150 WHERE id = $1", [account_id])

        assert [%{check: :negative_available, subject: subject, detail: detail}] = Audit.run()
        assert subject == account.id
        assert detail == %{balance_minor: 100, held_minor: 150}

        Repo.rollback(:done)
      end)

      # The rollback restored the constraint.
      assert %{rows: [[1]]} =
               sql!(
                 "SELECT count(*)::int FROM pg_constraint WHERE conname = 'accounts_available_non_negative'"
               )
    end
  end
end
