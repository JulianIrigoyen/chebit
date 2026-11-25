defmodule Chebit.Payments.DbConstraintsTest do
  # Each test goes around the application with raw SQL, to prove that the database refuses
  # the write on its own.
  use Chebit.DataCase, async: true

  alias Chebit.Fixtures
  alias Chebit.Payments
  alias Chebit.Payments.StateMachine

  defp intent_with_status(status) do
    %{merchant: merchant} = Fixtures.merchant_fixture()

    {:ok, intent} =
      Payments.create_intent(merchant, Ecto.UUID.generate(), %{amount_minor: 500, currency: "ARS"})

    set_status(intent.id, status)
    intent
  end

  defp set_status(intent_id, status) do
    Repo.query("UPDATE payment_intents SET status = $1 WHERE id = $2", [
      Atom.to_string(status),
      Ecto.UUID.dump!(intent_id)
    ])
  end

  describe "trigger payment_intents_terminal_status (invariant 6)" do
    test "refuses each change of status from each terminal status" do
      for from <- StateMachine.terminal_statuses(), to <- StateMachine.statuses(), to != from do
        intent = intent_with_status(from)

        assert {:error,
                %Postgrex.Error{postgres: %{constraint: "payment_intents_terminal_status"}}} =
                 set_status(intent.id, to)

        assert Repo.reload!(intent).status == from
      end
    end

    test "still lets other columns of a terminal intent change" do
      intent = intent_with_status(:final)

      assert {:ok, %{num_rows: 1}} =
               Repo.query("UPDATE payment_intents SET description = 'note' WHERE id = $1", [
                 Ecto.UUID.dump!(intent.id)
               ])
    end

    test "lets a status that is not terminal change" do
      for from <- StateMachine.statuses() -- StateMachine.terminal_statuses() do
        intent = intent_with_status(from)
        assert {:ok, %{num_rows: 1}} = set_status(intent.id, :final)
      end
    end
  end

  describe "check constraints of payment_intents" do
    test "refuses an unknown status, an amount of zero and an unknown currency" do
      intent = intent_with_status(:created)
      id = Ecto.UUID.dump!(intent.id)

      for {sql, constraint} <- [
            {"UPDATE payment_intents SET status = 'settled' WHERE id = $1",
             "payment_intents_status_valid"},
            {"UPDATE payment_intents SET amount_minor = 0 WHERE id = $1",
             "payment_intents_amount_positive"},
            {"UPDATE payment_intents SET currency = 'EUR' WHERE id = $1",
             "payment_intents_currency_valid"}
          ] do
        assert {:error, %Postgrex.Error{postgres: %{constraint: ^constraint}}} =
                 Repo.query(sql, [id])
      end
    end
  end
end
