defmodule Chebit.Payments.ConcurrencyTest do
  use Chebit.UnboxedCase

  alias Chebit.Fixtures
  alias Chebit.Ledger.Audit
  alias Chebit.Ledger.Hold
  alias Chebit.Ledger.Transaction
  alias Chebit.Payments
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.Intent
  alias Chebit.Providers.Simulated
  alias Chebit.Webhooks.ProviderEvent

  @callers 20

  defp merchant!(fee_bps \\ 250), do: Fixtures.merchant_fixture(%{fee_bps: fee_bps}).merchant

  defp attempts(intent),
    do: Repo.all(from a in Attempt, where: a.payment_intent_id == ^intent.id)

  defp paid_transactions(intent) do
    Repo.all(
      from t in Transaction,
        where:
          t.source_type == "payment_intent" and t.source_id == ^intent.id and
            t.kind == "payment_paid"
    )
  end

  defp holds(intent) do
    Repo.all(
      from h in Hold, where: h.source_type == "payment_intent" and h.source_id == ^intent.id
    )
  end

  test "20 concurrent confirms of one intent make one attempt and one provider payment" do
    merchant = merchant!()
    intent = Fixtures.intent_fixture(merchant)

    results =
      race(
        for _ <- 1..@callers,
            do: fn -> Payments.confirm_intent(merchant.id, intent.id, "simulated") end
      )

    assert Enum.all?(results, &match?({:ok, %Intent{status: :pending}}, &1)), inspect(results)
    assert [attempt] = attempts(intent)
    assert attempt.status == :dispatched
    assert Simulated.created_count(attempt.id) == 1

    assert Fixtures.intent_event_types(intent) == [
             "payment_intent.created",
             "payment_intent.pending"
           ]

    assert Audit.run() == []
  end

  test "20 concurrent syncs of a paid payment post one transaction, one hold, one event" do
    %{merchant: merchant, intent: intent, attempt: attempt} =
      Fixtures.pending_payment_fixture(fee_bps: 250)

    {:ok, _} = Simulated.pay(attempt.id, :delayed)

    results = race(for _ <- 1..@callers, do: fn -> Payments.sync_attempt(attempt.id) end)

    assert Enum.all?(results, &match?({:ok, %Intent{status: :paid}}, &1)), inspect(results)
    assert [_one] = paid_transactions(intent)
    assert [%Hold{amount_minor: 9_750, status: :active}] = holds(intent)

    assert Fixtures.intent_event_types(intent) ==
             ["payment_intent.created", "payment_intent.pending", "payment_intent.paid"]

    b = Fixtures.payment_balances(merchant)
    assert %{balance_minor: 9_750, held_minor: 9_750} = b.merchant
    assert b.fees.balance_minor == 250
    assert b.clearing.balance_minor == -10_000
    assert Audit.run() == []
  end

  test "syncs raced against a finalize end final with one event per status" do
    %{merchant: merchant, intent: intent, attempt: attempt} =
      Fixtures.pending_payment_fixture(fee_bps: 250)

    {:ok, _} = Simulated.pay(attempt.id, :delayed)
    sync = fn -> Payments.sync_attempt(attempt.id) end
    finalize = fn -> Simulated.finalize(attempt.id) end

    results =
      race(for(_ <- 1..10, do: sync) ++ [finalize] ++ for(_ <- 1..10, do: sync))

    sync_results = Enum.reject(results, &match?({:ok, %{body: _}}, &1))
    assert Enum.all?(sync_results, &match?({:ok, %Intent{}}, &1)), inspect(sync_results)

    assert {:ok, %Intent{status: :final}} = Payments.sync_attempt(attempt.id)

    assert Fixtures.intent_event_types(intent) ==
             [
               "payment_intent.created",
               "payment_intent.pending",
               "payment_intent.paid",
               "payment_intent.final"
             ]

    assert [_one] = paid_transactions(intent)
    assert [%Hold{status: :released}] = holds(intent)
    b = Fixtures.payment_balances(merchant)
    assert %{balance_minor: 9_750, held_minor: 0} = b.merchant
    assert Audit.run() == []
  end

  test "syncs raced against pay then finalize end final with one event per status" do
    %{merchant: merchant, intent: intent, attempt: attempt} =
      Fixtures.pending_payment_fixture(fee_bps: 250)

    sync = fn -> Payments.sync_attempt(attempt.id) end

    steps = fn ->
      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      {:ok, _} = Simulated.finalize(attempt.id)
      :steps_done
    end

    results = race(for(_ <- 1..10, do: sync) ++ [steps] ++ for(_ <- 1..10, do: sync))

    sync_results = Enum.reject(results, &(&1 == :steps_done))
    assert Enum.all?(sync_results, &match?({:ok, %Intent{}}, &1)), inspect(sync_results)

    assert {:ok, %Intent{status: :final}} = Payments.sync_attempt(attempt.id)

    assert Fixtures.intent_event_types(intent) ==
             [
               "payment_intent.created",
               "payment_intent.pending",
               "payment_intent.paid",
               "payment_intent.final"
             ]

    assert [_one] = paid_transactions(intent)
    assert [%Hold{status: :released}] = holds(intent)
    assert %{balance_minor: 9_750, held_minor: 0} = Fixtures.payment_balances(merchant).merchant
    assert Audit.run() == []
  end

  test "20 concurrent create_intent calls with one key make one intent and one event" do
    merchant = merchant!()

    results =
      race(
        for _ <- 1..@callers,
            do: fn ->
              Payments.create_intent(merchant, "one-key", %{
                "amount_minor" => 5_000,
                "currency" => "ARS"
              })
            end
      )

    assert Enum.all?(results, &match?({:ok, %Intent{}}, &1)), inspect(results)
    ids = results |> Enum.map(fn {:ok, intent} -> intent.id end) |> Enum.uniq()
    assert [id] = ids

    assert Repo.aggregate(from(i in Intent, where: i.merchant_id == ^merchant.id), :count) == 1
    assert Fixtures.intent_event_types(%Intent{id: id}) == ["payment_intent.created"]
  end

  test "20 concurrent ingests of one delivery store one row, accept once, enqueue one job" do
    %{attempt: attempt} = Fixtures.pending_payment_fixture()
    {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt.id, :delayed)

    results =
      race(for _ <- 1..@callers, do: fn -> Chebit.Webhooks.ingest("simulated", body, headers) end)

    assert Enum.count(results, &(&1 == {:ok, :accepted})) == 1, inspect(results)
    assert Enum.count(results, &(&1 == {:ok, :duplicate})) == @callers - 1

    assert [%ProviderEvent{id: event_id, reference: reference}] = Repo.all(ProviderEvent)
    assert reference == attempt.id

    jobs =
      Repo.all(from j in Oban.Job, where: j.worker == "Chebit.Webhooks.ProcessWorker")

    assert [%Oban.Job{args: %{"provider_event_id" => ^event_id}}] = jobs
  end
end
