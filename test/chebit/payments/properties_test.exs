defmodule Chebit.Payments.PropertiesTest do
  use Chebit.DataCase, async: true
  use ExUnitProperties

  alias Chebit.Fixtures
  alias Chebit.Ledger.Audit
  alias Chebit.Ledger.Transaction
  alias Chebit.Money
  alias Chebit.Payments
  alias Chebit.Payments.StateMachine
  alias Chebit.Providers.Simulated

  @controls [:pay_instant, :pay_delayed, :finalize, :fail, :expire, :dispute, :refund]

  defp operation do
    frequency([
      {5, tuple({constant(:control), member_of(@controls)})},
      {4, tuple({constant(:deliver), integer(0..50)})},
      {1, constant(:snapshot)},
      {1, constant(:sync)}
    ])
  end

  defp control(:pay_instant, id), do: Simulated.pay(id, :instant)
  defp control(:pay_delayed, id), do: Simulated.pay(id, :delayed)
  defp control(:finalize, id), do: Simulated.finalize(id)
  defp control(:fail, id), do: Simulated.fail(id, "card_declined")
  defp control(:expire, id), do: Simulated.expire(id)
  defp control(:dispute, id), do: Simulated.dispute(id)
  defp control(:refund, id), do: Simulated.refund(id)

  # Plays the operations. Returns every webhook that a control or a snapshot produced.
  defp play(ops, attempt_id) do
    Enum.reduce(ops, [], fn
      {:control, name}, hooks ->
        case control(name, attempt_id) do
          {:ok, delivery} -> hooks ++ [delivery]
          {:error, :invalid_state} -> hooks
        end

      {:deliver, _n}, [] ->
        []

      {:deliver, n}, hooks ->
        delivery = Enum.at(hooks, rem(n, length(hooks)))
        assert {{:ok, _ingest}, :ok} = Fixtures.deliver_webhook(delivery)
        hooks

      :snapshot, hooks ->
        {:ok, delivery} = Simulated.webhook_for(attempt_id)
        hooks ++ [delivery]

      :sync, hooks ->
        assert {:ok, _intent} = Payments.sync_attempt(attempt_id)
        hooks
    end)
  end

  defp statuses_of(intent) do
    intent
    |> Fixtures.intent_event_types()
    |> Enum.map(fn "payment_intent." <> status -> String.to_existing_atom(status) end)
  end

  property "any control sequence and any webhook delivery order end in the provider state with a consistent ledger" do
    check all(
            amount <- integer(1..1_000_000),
            currency <- member_of(Money.currencies()),
            fee_bps <- one_of([constant(0), integer(0..10_000), member_of([250, 10_000])]),
            ops <- list_of(operation(), max_length: 14),
            max_runs: 40
          ) do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(
          fee_bps: fee_bps,
          amount_minor: amount,
          currency: currency
        )

      # House accounts persist across the runs of one property: compare with deltas.
      before = Fixtures.payment_balances(merchant, currency)

      play(ops, attempt.id)
      assert {:ok, final_intent} = Payments.sync_attempt(attempt.id)

      # (a) the intent follows the provider.
      assert {:ok, provider_payment} = Simulated.fetch_payment(attempt.id)
      assert final_intent.status == provider_payment.status
      assert Fixtures.reload_intent(intent).status == provider_payment.status

      # (b) events only move forward, and nothing follows a terminal status.
      statuses = statuses_of(intent)
      ranks = Enum.map(statuses, &StateMachine.rank/1)
      assert ranks == Enum.sort(ranks), "ranks went down: #{inspect(statuses)}"
      assert statuses == Enum.uniq(statuses), "repeated status: #{inspect(statuses)}"

      {_before_terminal, from_terminal} =
        Enum.split_while(statuses, &(not StateMachine.terminal?(&1)))

      assert length(from_terminal) <= 1, "event after terminal: #{inspect(statuses)}"
      assert List.last(statuses) == final_intent.status

      # (c) the ledger audit is clean.
      assert Audit.run() == []

      # (d) the merchant balance and hold match the status.
      fee = Money.fee_minor(amount, fee_bps)
      net = amount - fee
      b = Fixtures.payment_balances(merchant, currency)

      {merchant_balance, merchant_held} =
        case final_intent.status do
          :final -> {net, 0}
          status when status in [:paid, :disputed] -> {net, net}
          _other -> {0, 0}
        end

      assert b.merchant.balance_minor == merchant_balance
      assert b.merchant.held_minor == merchant_held

      # (e) clearing and fees.
      {cleared, fees} =
        if final_intent.status in [:paid, :disputed, :final], do: {-amount, fee}, else: {0, 0}

      assert b.clearing.balance_minor - before.clearing.balance_minor == cleared
      assert b.fees.balance_minor - before.fees.balance_minor == fees

      # A further sync is a no-op.
      tx_count = Repo.aggregate(Transaction, :count)
      assert {:ok, _} = Payments.sync_attempt(attempt.id)
      assert Repo.aggregate(Transaction, :count) == tx_count
      assert statuses_of(intent) == statuses
    end
  end
end
