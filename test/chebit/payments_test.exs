defmodule Chebit.PaymentsTest do
  use Chebit.DataCase, async: true

  alias Chebit.Fixtures
  alias Chebit.Ledger
  alias Chebit.Ledger.Audit
  alias Chebit.Ledger.Transaction
  alias Chebit.Payments
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.Intent
  alias Chebit.Providers.Simulated

  @created "payment_intent.created"

  defp attrs(overrides \\ %{}),
    do: Map.merge(%{"amount_minor" => 10_000, "currency" => "ARS"}, overrides)

  defp merchant!(fee_bps \\ 0), do: Fixtures.merchant_fixture(%{fee_bps: fee_bps}).merchant

  defp sync!(attempt) do
    assert {:ok, %Intent{} = intent} = Payments.sync_attempt(attempt.id)
    intent
  end

  defp hold!(intent) do
    {:ok, hold} = Ledger.fetch_hold("payment_intent", intent.id)
    hold
  end

  # Creates an intent, inserts its attempt, and arms a fault for the first provider call.
  defp faulted(fault) do
    merchant = merchant!()
    intent = Fixtures.intent_fixture(merchant)
    attempt = Repo.insert!(%Attempt{payment_intent_id: intent.id, provider: "simulated"})
    :ok = Simulated.fault_next_create(attempt.id, fault)
    {merchant, intent, attempt}
  end

  defp attempts(intent),
    do:
      Repo.all(
        from a in Attempt, where: a.payment_intent_id == ^intent.id, order_by: a.inserted_at
      )

  describe "create_intent/3" do
    test "creates a created intent with an expiry in the future and one event" do
      merchant = merchant!()

      assert {:ok, %Intent{} = intent} =
               Payments.create_intent(
                 merchant,
                 "k1",
                 attrs(%{"description" => "mate", "metadata" => %{"order" => "7"}})
               )

      assert intent.status == :created
      assert intent.amount_minor == 10_000
      assert intent.currency == :ARS
      assert intent.merchant_id == merchant.id
      assert intent.description == "mate"
      assert intent.metadata == %{"order" => "7"}
      assert intent.idempotency_key == "k1"
      assert DateTime.compare(intent.expires_at, DateTime.utc_now()) == :gt
      assert Fixtures.intent_event_types(intent) == [@created]
    end

    test "rejects missing fields" do
      assert {:error, changeset} = Payments.create_intent(merchant!(), "k", %{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.amount_minor
      assert "can't be blank" in errors.currency
    end

    test "rejects a float amount" do
      assert {:error, changeset} =
               Payments.create_intent(merchant!(), "k", attrs(%{"amount_minor" => 10.5}))

      assert %{amount_minor: [_ | _]} = errors_on(changeset)
    end

    test "rejects zero" do
      assert {:error, changeset} =
               Payments.create_intent(merchant!(), "k", attrs(%{"amount_minor" => 0}))

      assert %{amount_minor: [_ | _]} = errors_on(changeset)
    end

    test "rejects a negative amount" do
      assert {:error, changeset} =
               Payments.create_intent(merchant!(), "k", attrs(%{"amount_minor" => -5}))

      assert %{amount_minor: [_ | _]} = errors_on(changeset)
    end

    test "rejects an amount above bigint" do
      too_big = Chebit.Money.max_amount_minor() + 1

      assert {:error, changeset} =
               Payments.create_intent(merchant!(), "k", attrs(%{"amount_minor" => too_big}))

      assert %{amount_minor: [_ | _]} = errors_on(changeset)
    end

    test "accepts the bigint maximum" do
      max = Chebit.Money.max_amount_minor()

      assert {:ok, %Intent{amount_minor: ^max}} =
               Payments.create_intent(merchant!(), "k", attrs(%{"amount_minor" => max}))
    end

    test "rejects an unknown currency" do
      assert {:error, changeset} =
               Payments.create_intent(merchant!(), "k", attrs(%{"currency" => "XYZ"}))

      assert %{currency: [_ | _]} = errors_on(changeset)
    end

    test "rejects a description over 500 characters, accepts exactly 500" do
      merchant = merchant!()

      assert {:error, changeset} =
               Payments.create_intent(
                 merchant,
                 "k1",
                 attrs(%{"description" => String.duplicate("a", 501)})
               )

      assert %{description: [_ | _]} = errors_on(changeset)

      assert {:ok, _intent} =
               Payments.create_intent(
                 merchant,
                 "k2",
                 attrs(%{"description" => String.duplicate("a", 500)})
               )
    end

    test "a rejected request writes no intent and no event" do
      merchant = merchant!()
      assert {:error, _changeset} = Payments.create_intent(merchant, "k", %{})
      assert Repo.aggregate(from(i in Intent, where: i.merchant_id == ^merchant.id), :count) == 0
      assert Repo.aggregate(Chebit.Outbox.Event, :count) == 0
    end

    test "ignores status, merchant_id, expires_at, idempotency_key and id in attrs" do
      merchant = merchant!()
      other = merchant!()
      past = DateTime.add(DateTime.utc_now(), -3_600, :second) |> DateTime.to_iso8601()
      forged_id = Ecto.UUID.generate()

      assert {:ok, intent} =
               Payments.create_intent(
                 merchant,
                 "real-key",
                 attrs(%{
                   "status" => "paid",
                   "merchant_id" => other.id,
                   "expires_at" => past,
                   "idempotency_key" => "forged-key",
                   "failure_reason" => "forged",
                   "id" => forged_id
                 })
               )

      assert intent.status == :created
      assert intent.merchant_id == merchant.id
      assert intent.idempotency_key == "real-key"
      assert intent.failure_reason == nil
      assert intent.id != forged_id
      assert DateTime.compare(intent.expires_at, DateTime.utc_now()) == :gt
      assert reload = Fixtures.reload_intent(intent)
      assert reload.status == :created
      assert reload.merchant_id == merchant.id
    end

    test "the same key twice returns the same intent, one row and one created event" do
      merchant = merchant!()
      assert {:ok, first} = Payments.create_intent(merchant, "same", attrs())
      assert {:ok, second} = Payments.create_intent(merchant, "same", attrs())

      assert first.id == second.id
      assert Repo.aggregate(from(i in Intent, where: i.merchant_id == ^merchant.id), :count) == 1
      assert Fixtures.intent_event_types(first) == [@created]
    end

    test "the same key for two merchants gives two intents" do
      a = merchant!()
      b = merchant!()
      assert {:ok, ia} = Payments.create_intent(a, "shared", attrs())
      assert {:ok, ib} = Payments.create_intent(b, "shared", attrs())

      assert ia.id != ib.id
      assert ia.merchant_id == a.id
      assert ib.merchant_id == b.id
      assert Fixtures.intent_event_types(ia) == [@created]
      assert Fixtures.intent_event_types(ib) == [@created]
    end
  end

  describe "fetch_intent/2" do
    test "returns the intent of its owner with its attempts" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)

      assert {:ok, %Intent{} = found} = Payments.fetch_intent(merchant.id, intent.id)
      assert found.id == intent.id
      assert found.attempts == []
    end

    test "returns the attempts after a confirm" do
      %{merchant: merchant, intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      assert {:ok, found} = Payments.fetch_intent(merchant.id, intent.id)
      assert [%Attempt{id: id}] = found.attempts
      assert id == attempt.id
    end

    test "gives :not_found for another merchant" do
      merchant = merchant!()
      other = merchant!()
      intent = Fixtures.intent_fixture(merchant)
      assert Payments.fetch_intent(other.id, intent.id) == {:error, :not_found}
    end

    test "gives :not_found for a missing id" do
      assert Payments.fetch_intent(merchant!().id, Ecto.UUID.generate()) == {:error, :not_found}
    end

    test "gives :not_found for a malformed id and for nil" do
      merchant = merchant!()
      assert Payments.fetch_intent(merchant.id, "not-a-uuid") == {:error, :not_found}
      assert Payments.fetch_intent(merchant.id, nil) == {:error, :not_found}
    end
  end

  describe "confirm_intent/3" do
    test "moves the intent to pending with one dispatched attempt" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)

      assert {:ok, %Intent{status: :pending, attempts: [attempt]}} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert attempt.status == :dispatched
      assert attempt.provider == "simulated"
      assert "sim_" <> _ = attempt.external_id
      assert attempt.provider_status == "pending"
      assert attempt.payment_data == %{"qr" => "simulated:" <> attempt.external_id}
      assert Simulated.created_count(attempt.id) == 1
      assert Fixtures.intent_event_types(intent) == [@created, "payment_intent.pending"]
    end

    test "a second confirm creates no second provider payment and no second event" do
      %{merchant: merchant, intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()

      assert {:ok, %Intent{status: :pending, attempts: [again]}} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert again.id == attempt.id
      assert Simulated.created_count(attempt.id) == 1
      assert length(attempts(intent)) == 1
      assert Fixtures.intent_event_types(intent) == [@created, "payment_intent.pending"]
    end

    test "gives :unknown_provider for an unknown name and for a non-binary" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)

      assert Payments.confirm_intent(merchant.id, intent.id, "nope") ==
               {:error, :unknown_provider}

      assert Payments.confirm_intent(merchant.id, intent.id, :simulated) ==
               {:error, :unknown_provider}

      assert Payments.confirm_intent(merchant.id, intent.id, nil) == {:error, :unknown_provider}
      assert Payments.confirm_intent(merchant.id, intent.id, 7) == {:error, :unknown_provider}
      assert attempts(intent) == []
      assert Fixtures.reload_intent(intent).status == :created
    end

    test "gives :not_found for another merchant and creates no attempt" do
      merchant = merchant!()
      other = merchant!()
      intent = Fixtures.intent_fixture(merchant)

      assert Payments.confirm_intent(other.id, intent.id, "simulated") == {:error, :not_found}
      assert attempts(intent) == []
    end

    test "gives :not_found for a missing and a malformed intent id" do
      merchant = merchant!()

      assert Payments.confirm_intent(merchant.id, Ecto.UUID.generate(), "simulated") ==
               {:error, :not_found}

      assert Payments.confirm_intent(merchant.id, "x", "simulated") == {:error, :not_found}
    end

    test "refuses an intent past expires_at" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :invalid_state}

      assert attempts(intent) == []
      assert Fixtures.reload_intent(intent).status == :created
    end

    # A retry of a confirm that worked must not get an error, even when the payment moved
    # on in the meantime. The provider has the payment, so nothing is sent again.
    test "returns the intent as it is now once the provider has the payment" do
      for {control, status} <- [
            {fn id -> Simulated.pay(id, :instant) end, :final},
            {fn id -> Simulated.pay(id, :delayed) end, :paid},
            {fn id -> Simulated.fail(id, "x") end, :failed},
            {&Simulated.expire/1, :expired}
          ] do
        %{merchant: merchant, intent: intent, attempt: attempt} =
          Fixtures.pending_payment_fixture()

        {:ok, _} = control.(attempt.id)
        assert sync!(attempt).status == status
        events = Fixtures.intent_event_types(intent)

        assert {:ok, %Intent{status: ^status}} =
                 Payments.confirm_intent(merchant.id, intent.id, "simulated")

        assert length(attempts(intent)) == 1
        assert Simulated.created_count(attempt.id) == 1
        assert Fixtures.intent_event_types(intent) == events
      end
    end

    test "refuses an intent that expired before it reached a provider" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)
      past = DateTime.add(DateTime.utc_now(), -600, :second)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])
      assert {:ok, 1} = Payments.expire_due(DateTime.utc_now())

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :invalid_state}

      assert attempts(intent) == []
    end

    test "fault :decline gives :provider_declined, fails the attempt, keeps the intent created" do
      {merchant, intent, attempt} = faulted(:decline)

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :provider_declined}

      failed = Repo.get!(Attempt, attempt.id)
      assert failed.status == :failed
      assert failed.failure_reason == "provider_declined"
      assert Fixtures.reload_intent(intent).status == :created
      assert Simulated.created_count(attempt.id) == 0
      assert Fixtures.intent_event_types(intent) == [@created]

      # A new confirm opens a new attempt.
      assert {:ok, %Intent{status: :pending}} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert [first, second] = attempts(intent)
      assert first.id == attempt.id
      assert second.id != attempt.id
      assert second.status == :dispatched
      assert Simulated.created_count(second.id) == 1
      assert Simulated.created_count(first.id) == 0
      assert Fixtures.intent_event_types(intent) == [@created, "payment_intent.pending"]
    end

    test "fault :unavailable_before gives :provider_unavailable, a retry reaches pending once" do
      {merchant, intent, attempt} = faulted(:unavailable_before)

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :provider_unavailable}

      assert Simulated.created_count(attempt.id) == 0
      assert Repo.get!(Attempt, attempt.id).status == :initiated
      assert Fixtures.reload_intent(intent).status == :created

      assert {:ok, %Intent{status: :pending}} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert Simulated.created_count(attempt.id) == 1
      assert [only] = attempts(intent)
      assert only.id == attempt.id
      assert only.status == :dispatched
      assert Fixtures.intent_event_types(intent) == [@created, "payment_intent.pending"]
    end

    test "fault :unavailable_after (lost reply) is retried without a second payment" do
      {merchant, intent, attempt} = faulted(:unavailable_after)

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :provider_unavailable}

      assert Simulated.created_count(attempt.id) == 1
      assert Repo.get!(Attempt, attempt.id).status == :initiated
      assert Fixtures.reload_intent(intent).status == :created

      assert {:ok, %Intent{status: :pending, attempts: [done]}} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert done.id == attempt.id
      assert done.status == :dispatched
      assert Simulated.created_count(attempt.id) == 1
      assert length(attempts(intent)) == 1
      assert Fixtures.intent_event_types(intent) == [@created, "payment_intent.pending"]
    end
  end

  describe "sync_attempt/1" do
    test "instant pay: pending to final, the merchant share is free" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.pay(attempt.id, :instant)
      assert %Intent{status: :final} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 9_750, held_minor: 0, available_minor: 9_750} = b.merchant
      assert b.fees.balance_minor == 250
      assert b.clearing.balance_minor == -10_000
      assert hold!(intent).status == :released
      assert Audit.run() == []

      assert Fixtures.intent_event_types(intent) ==
               [@created, "payment_intent.pending", "payment_intent.paid", "payment_intent.final"]
    end

    test "delayed pay: paid holds the whole share, finalize releases it" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      assert %Intent{status: :paid} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 9_750, held_minor: 9_750, available_minor: 0} = b.merchant
      assert b.fees.balance_minor == 250
      assert b.clearing.balance_minor == -10_000
      assert %{status: :active, amount_minor: 9_750} = hold!(intent)
      assert Audit.run() == []

      {:ok, _} = Simulated.finalize(attempt.id)
      assert %Intent{status: :final} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 9_750, held_minor: 0, available_minor: 9_750} = b.merchant
      assert b.fees.balance_minor == 250
      assert b.clearing.balance_minor == -10_000
      assert hold!(intent).status == :released
      assert Audit.run() == []

      assert Fixtures.intent_event_types(intent) ==
               [@created, "payment_intent.pending", "payment_intent.paid", "payment_intent.final"]
    end

    test "paid then refund: every balance returns to 0, the hold is captured" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)
      {:ok, _} = Simulated.refund(attempt.id)

      assert %Intent{status: :refunded, failure_reason: "refunded"} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 0, held_minor: 0, available_minor: 0} = b.merchant
      assert b.fees.balance_minor == 0
      assert b.clearing.balance_minor == 0
      assert hold!(intent).status == :captured
      assert Audit.run() == []

      assert Fixtures.intent_event_types(intent) ==
               [
                 @created,
                 "payment_intent.pending",
                 "payment_intent.paid",
                 "payment_intent.refunded"
               ]
    end

    test "paid then dispute: no ledger change, then finalize releases the hold" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)
      before_dispute = Fixtures.payment_balances(merchant)
      tx_count = Repo.aggregate(Transaction, :count)

      {:ok, _} = Simulated.dispute(attempt.id)
      assert %Intent{status: :disputed} = sync!(attempt)

      assert Fixtures.payment_balances(merchant) == before_dispute
      assert Repo.aggregate(Transaction, :count) == tx_count
      assert hold!(intent).status == :active
      assert Audit.run() == []

      {:ok, _} = Simulated.finalize(attempt.id)
      assert %Intent{status: :final} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 9_750, held_minor: 0, available_minor: 9_750} = b.merchant
      assert hold!(intent).status == :released
      assert Audit.run() == []

      assert Fixtures.intent_event_types(intent) ==
               [
                 @created,
                 "payment_intent.pending",
                 "payment_intent.paid",
                 "payment_intent.disputed",
                 "payment_intent.final"
               ]
    end

    test "disputed then refund: refunded with failure_reason dispute_lost" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)
      {:ok, _} = Simulated.dispute(attempt.id)
      sync!(attempt)
      {:ok, _} = Simulated.refund(attempt.id)

      assert %Intent{status: :refunded, failure_reason: "dispute_lost"} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 0, held_minor: 0} = b.merchant
      assert b.fees.balance_minor == 0
      assert b.clearing.balance_minor == 0
      assert hold!(intent).status == :captured
      assert Audit.run() == []
    end

    test "provider fail with a reason: failed with that failure_reason, no money moved" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.fail(attempt.id, "insufficient_funds")

      assert %Intent{status: :failed, failure_reason: "insufficient_funds"} = sync!(attempt)
      assert Fixtures.reload_intent(intent).failure_reason == "insufficient_funds"

      b = Fixtures.payment_balances(merchant)
      assert b.merchant.balance_minor == 0
      assert b.fees.balance_minor == 0
      assert b.clearing.balance_minor == 0
      assert Ledger.fetch_hold("payment_intent", intent.id) == {:error, :hold_not_found}

      assert Fixtures.intent_event_types(intent) == [
               @created,
               "payment_intent.pending",
               "payment_intent.failed"
             ]

      assert Audit.run() == []
    end

    test "provider expire: expired, no money moved" do
      %{merchant: merchant, intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, _} = Simulated.expire(attempt.id)

      assert %Intent{status: :expired, failure_reason: "expired"} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert b.merchant.balance_minor == 0
      assert b.clearing.balance_minor == 0

      assert Fixtures.intent_event_types(intent) ==
               [@created, "payment_intent.pending", "payment_intent.expired"]

      assert Audit.run() == []
    end

    test "fee of 250 bps on 10_000 is 250, the merchant gets 9_750" do
      %{merchant: merchant, attempt: attempt} = Fixtures.pending_payment_fixture(fee_bps: 250)
      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert b.merchant.balance_minor == 9_750
      assert b.fees.balance_minor == 250
      assert b.clearing.balance_minor == -10_000
      assert Audit.run() == []
    end

    test "fee of 250 bps on an amount of 1 rounds to 0" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250, amount_minor: 1)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 1, held_minor: 1} = b.merchant
      assert b.fees.balance_minor == 0
      assert b.clearing.balance_minor == -1
      assert hold!(intent).amount_minor == 1
      assert Audit.run() == []

      {:ok, _} = Simulated.finalize(attempt.id)
      assert %Intent{status: :final} = sync!(attempt)
      assert %{balance_minor: 1, held_minor: 0} = Fixtures.payment_balances(merchant).merchant
      assert Audit.run() == []
    end

    test "fee of 10_000 bps: the merchant gets nothing, no hold, refund still reverses" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 10_000)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      assert %Intent{status: :paid} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 0, held_minor: 0} = b.merchant
      assert b.fees.balance_minor == 10_000
      assert b.clearing.balance_minor == -10_000
      assert Ledger.fetch_hold("payment_intent", intent.id) == {:error, :hold_not_found}
      assert Audit.run() == []

      {:ok, _} = Simulated.refund(attempt.id)
      assert %Intent{status: :refunded} = sync!(attempt)

      b = Fixtures.payment_balances(merchant)
      assert b.merchant.balance_minor == 0
      assert b.fees.balance_minor == 0
      assert b.clearing.balance_minor == 0
      assert Audit.run() == []
    end

    test "fee of 10_000 bps with instant pay reaches final without a hold" do
      %{merchant: merchant, attempt: attempt} = Fixtures.pending_payment_fixture(fee_bps: 10_000)
      {:ok, _} = Simulated.pay(attempt.id, :instant)
      assert %Intent{status: :final} = sync!(attempt)
      assert Fixtures.payment_balances(merchant).fees.balance_minor == 10_000
      assert Audit.run() == []
    end

    test "a second sync in the same state writes no transaction and no event" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)

      tx_count = Repo.aggregate(Transaction, :count)
      events = Fixtures.intent_event_types(intent)
      balances = Fixtures.payment_balances(merchant)
      event_total = Repo.aggregate(Chebit.Outbox.Event, :count)

      assert %Intent{status: :paid} = sync!(attempt)
      assert %Intent{status: :paid} = sync!(attempt)

      assert Repo.aggregate(Transaction, :count) == tx_count
      assert Fixtures.intent_event_types(intent) == events
      assert Repo.aggregate(Chebit.Outbox.Event, :count) == event_total
      assert Fixtures.payment_balances(merchant) == balances
      assert Audit.run() == []
    end

    test "sync of a pending payment changes nothing" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      assert %Intent{status: :pending} = sync!(attempt)
      assert Fixtures.intent_event_types(intent) == [@created, "payment_intent.pending"]
    end

    test "the provider reports final while our intent is expired: :invalid_transition, nothing changes" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      # The intent expired here while the payer paid at the provider.
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
        set: [status: :expired, failure_reason: "expired"]
      )

      {:ok, _} = Simulated.pay(attempt.id, :instant)
      events = Fixtures.intent_event_types(intent)
      tx_count = Repo.aggregate(Transaction, :count)

      assert Payments.sync_attempt(attempt.id) == {:error, :invalid_transition}

      reloaded = Fixtures.reload_intent(intent)
      assert reloaded.status == :expired
      assert reloaded.failure_reason == "expired"
      assert Fixtures.intent_event_types(intent) == events
      assert Repo.aggregate(Transaction, :count) == tx_count
      b = Fixtures.payment_balances(merchant)
      assert b.merchant.balance_minor == 0
      assert b.clearing.balance_minor == 0
      assert b.fees.balance_minor == 0
      assert Ledger.fetch_hold("payment_intent", intent.id) == {:error, :hold_not_found}
      assert Audit.run() == []
    end

    test "gives :not_found for an unknown or malformed attempt id" do
      assert Payments.sync_attempt(Ecto.UUID.generate()) == {:error, :not_found}
      assert Payments.sync_attempt("nope") == {:error, :not_found}
      assert Payments.sync_attempt(nil) == {:error, :not_found}
    end

    test "gives :payment_not_found when the provider has no payment for the attempt" do
      {_merchant, intent, attempt} = faulted(:unavailable_before)

      assert Payments.confirm_intent(intent.merchant_id, intent.id, "simulated") ==
               {:error, :provider_unavailable}

      assert Payments.sync_attempt(attempt.id) == {:error, :payment_not_found}
    end

    test "the event types of an intent follow the statuses it went through, in id order" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      sync!(attempt)
      {:ok, _} = Simulated.dispute(attempt.id)
      sync!(attempt)
      {:ok, _} = Simulated.refund(attempt.id)
      sync!(attempt)

      assert Fixtures.intent_event_types(intent) ==
               Enum.map(
                 [:created, :pending, :paid, :disputed, :refunded],
                 &"payment_intent.#{&1}"
               )
    end

    test "a catch-up sync from pending applies each missed step in order" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      {:ok, _} = Simulated.dispute(attempt.id)
      {:ok, _} = Simulated.refund(attempt.id)

      assert %Intent{status: :refunded} = sync!(attempt)

      assert Fixtures.intent_event_types(intent) ==
               Enum.map([:created, :pending, :paid, :refunded], &"payment_intent.#{&1}")

      assert Audit.run() == []
    end
  end

  describe "sync_attempt/1 in each currency and at the amount limits" do
    test "each currency moves the same way" do
      for currency <- Chebit.Money.currencies() do
        %{merchant: merchant, intent: intent, attempt: attempt} =
          Fixtures.pending_payment_fixture(fee_bps: 250, currency: currency)

        {:ok, _} = Simulated.pay(attempt.id, :delayed)
        assert %Intent{status: :paid, currency: ^currency} = sync!(attempt)

        b = Fixtures.payment_balances(merchant, currency)
        assert %{balance_minor: 9_750, held_minor: 9_750, currency: ^currency} = b.merchant
        assert b.fees.balance_minor == 250
        assert b.clearing.balance_minor == -10_000
        assert hold!(intent).status == :active
        assert Audit.run() == []
      end
    end

    test "a payment at the bigint maximum is paid and refunded" do
      max = Chebit.Money.max_amount_minor()

      %{merchant: merchant, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250, amount_minor: max)

      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      assert %Intent{status: :paid} = sync!(attempt)
      b = Fixtures.payment_balances(merchant)
      assert b.clearing.balance_minor == -max
      assert b.merchant.balance_minor + b.fees.balance_minor == max
      assert Audit.run() == []

      {:ok, _} = Simulated.refund(attempt.id)
      assert %Intent{status: :refunded} = sync!(attempt)
      assert Fixtures.payment_balances(merchant).clearing.balance_minor == 0
    end

    # The create validation accepts any amount up to the bigint maximum. The clearing account
    # of a provider sums many payments, so two such payments overflow it. The call must
    # return an error atom and change nothing. It must not raise.
    test "two payments at the bigint maximum in one currency do not raise" do
      max = Chebit.Money.max_amount_minor()
      first = Fixtures.pending_payment_fixture(amount_minor: max)
      {:ok, _} = Simulated.pay(first.attempt.id, :delayed)
      assert %Intent{status: :paid} = sync!(first.attempt)

      second = Fixtures.pending_payment_fixture(amount_minor: max)
      {:ok, _} = Simulated.pay(second.attempt.id, :delayed)

      result =
        try do
          Payments.sync_attempt(second.attempt.id)
        rescue
          error -> {:raised, error}
        end

      assert result == {:error, :balance_out_of_range}
      assert Fixtures.reload_intent(second.intent).status == :pending
      assert Audit.run() == []
    end
  end

  describe "rejected input" do
    test "confirm_intent/3 and fetch_intent/2 do not raise on junk ids" do
      merchant = merchant!()

      for junk <- [nil, 123, %{}, [], "", "00000000-0000-0000-0000-00000000000"] do
        assert Payments.confirm_intent(merchant.id, junk, "simulated") == {:error, :not_found}
        assert Payments.fetch_intent(merchant.id, junk) == {:error, :not_found}
        assert Payments.sync_attempt(junk) == {:error, :not_found}
      end
    end

    test "create_intent/3 returns a changeset for fields of the wrong type" do
      merchant = merchant!()

      for bad <- [
            attrs(%{"amount_minor" => "ten"}),
            attrs(%{"amount_minor" => nil}),
            attrs(%{"amount_minor" => [1]}),
            attrs(%{"currency" => 5}),
            attrs(%{"currency" => nil}),
            attrs(%{"description" => 12}),
            attrs(%{"metadata" => "text"})
          ] do
        assert {:error, %Ecto.Changeset{valid?: false}} =
                 Payments.create_intent(merchant, "k-#{System.unique_integer()}", bad)
      end
    end

    # Phoenix params never mix key types, so only an internal caller can pass this.
    test "create_intent/3 does not raise on attrs that mix string and atom keys" do
      merchant = merchant!()
      mixed = %{"amount_minor" => 100, currency: "ARS"}

      result =
        try do
          Payments.create_intent(merchant, "mixed", mixed)
        rescue
          error -> {:raised, error}
        end

      assert {:ok, %Intent{amount_minor: 100, currency: :ARS}} = result
    end

    test "create_intent/3 reads a null metadata as no metadata" do
      merchant = merchant!()

      assert {:ok, %Intent{metadata: metadata}} =
               Payments.create_intent(merchant, "null-meta", attrs(%{"metadata" => nil}))

      assert metadata == %{}
    end

    test "create_intent/3 refuses the same key with another amount, currency or description" do
      merchant = merchant!()

      assert {:ok, first} =
               Payments.create_intent(merchant, "same", attrs(%{"amount_minor" => 100}))

      for other <- [
            attrs(%{"amount_minor" => 101}),
            attrs(%{"amount_minor" => 100, "currency" => "BTC"}),
            attrs(%{"amount_minor" => 100, "description" => "another order"})
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Payments.create_intent(merchant, "same", other)

        assert %{idempotency_key: ["was used with another request"]} = errors_on(changeset)
      end

      assert Fixtures.reload_intent(first).amount_minor == 100
    end

    test "a rejected request leaves the ledger untouched" do
      merchant = merchant!()
      assert {:error, _} = Payments.create_intent(merchant, "k", %{})
      assert Audit.run() == []
      assert Repo.aggregate(Transaction, :count) == 0
    end
  end
end
