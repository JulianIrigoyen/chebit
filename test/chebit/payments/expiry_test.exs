defmodule Chebit.Payments.ExpiryTest do
  use Chebit.DataCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  alias Chebit.Fixtures
  alias Chebit.Ledger
  alias Chebit.Ledger.Audit
  alias Chebit.Payments
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.ExpiryWorker
  alias Chebit.Payments.Intent
  alias Chebit.Providers.Simulated

  # Ten minutes: past `expires_at`, and past the grace before an unknown attempt is abandoned.
  defp make_due(intent, seconds_ago \\ 600) do
    past = DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])
    :ok
  end

  defp expire_due!(now \\ DateTime.utc_now()) do
    assert {:ok, count} = Payments.expire_due(now)
    count
  end

  defp merchant!, do: Fixtures.merchant_fixture(%{fee_bps: 250}).merchant

  describe "expire_due/1" do
    test "expires a created intent with no attempt, with event and failure_reason" do
      intent = Fixtures.intent_fixture(merchant!())
      make_due(intent)

      assert expire_due!() == 1

      reloaded = Fixtures.reload_intent(intent)
      assert reloaded.status == :expired
      assert reloaded.failure_reason == "expired"

      assert Fixtures.intent_event_types(intent) ==
               ["payment_intent.created", "payment_intent.expired"]

      assert Audit.run() == []
    end

    test "leaves an intent that is not due untouched" do
      intent = Fixtures.intent_fixture(merchant!())

      assert expire_due!() == 0
      assert Fixtures.reload_intent(intent).status == :created
      assert Fixtures.intent_event_types(intent) == ["payment_intent.created"]
    end

    test "a now in the future makes the intent due" do
      intent = Fixtures.intent_fixture(merchant!())
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert expire_due!(later) == 1
      assert Fixtures.reload_intent(intent).status == :expired
    end

    test "a second run counts nothing and writes no second event" do
      intent = Fixtures.intent_fixture(merchant!())
      make_due(intent)

      assert expire_due!() == 1
      assert expire_due!() == 0

      assert Fixtures.intent_event_types(intent) ==
               ["payment_intent.created", "payment_intent.expired"]
    end

    test "a pending intent whose provider payment expired becomes expired" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, _webhook_not_delivered} = Simulated.expire(attempt.id)
      make_due(intent)

      assert expire_due!() == 1

      reloaded = Fixtures.reload_intent(intent)
      assert reloaded.status == :expired
      assert reloaded.failure_reason == "expired"

      assert Fixtures.intent_event_types(intent) ==
               ["payment_intent.created", "payment_intent.pending", "payment_intent.expired"]
    end

    test "a pending intent whose provider payment is still pending stays pending, not counted" do
      %{intent: intent} = Fixtures.pending_payment_fixture()
      make_due(intent)

      assert expire_due!() == 0

      assert Fixtures.reload_intent(intent).status == :pending

      assert Fixtures.intent_event_types(intent) ==
               ["payment_intent.created", "payment_intent.pending"]
    end

    test "provider paid with the webhook lost: the sweep brings the intent to final and moves the money" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _lost_webhook} = Simulated.pay(attempt.id, :instant)
      make_due(intent)

      assert expire_due!() == 0

      assert Fixtures.reload_intent(intent).status == :final
      b = Fixtures.payment_balances(merchant)
      assert %{balance_minor: 9_750, held_minor: 0} = b.merchant
      assert b.fees.balance_minor == 250
      assert b.clearing.balance_minor == -10_000
      assert Audit.run() == []

      assert Fixtures.intent_event_types(intent) ==
               [
                 "payment_intent.created",
                 "payment_intent.pending",
                 "payment_intent.paid",
                 "payment_intent.final"
               ]
    end

    test "provider paid (delayed) with the webhook lost: the sweep moves the intent to paid" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _lost_webhook} = Simulated.pay(attempt.id, :delayed)
      make_due(intent)

      assert expire_due!() == 0

      assert Fixtures.reload_intent(intent).status == :paid

      assert %{balance_minor: 9_750, held_minor: 9_750} =
               Fixtures.payment_balances(merchant).merchant

      assert {:ok, _hold} = Ledger.fetch_hold("payment_intent", intent.id)
      assert Audit.run() == []
    end

    test "an initiated attempt that the provider does not know: intent expired, attempt failed" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)
      attempt = Repo.insert!(%Attempt{payment_intent_id: intent.id, provider: "simulated"})
      :ok = Simulated.fault_next_create(attempt.id, :unavailable_before)

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :provider_unavailable}

      make_due(intent)

      assert expire_due!() == 1

      assert Fixtures.reload_intent(intent).status == :expired
      failed = Repo.get!(Attempt, attempt.id)
      assert failed.status == :failed
      assert failed.failure_reason == "expired"
      assert Simulated.created_count(attempt.id) == 0

      assert Fixtures.intent_event_types(intent) ==
               ["payment_intent.created", "payment_intent.expired"]
    end

    test "one call reaches each due intent, even when the oldest ones stay pending" do
      # Three intents that the provider still reports as `pending`, older than two that
      # never reached a provider. With pages of two, the first page holds only stuck ones.
      stuck = for _n <- 1..3, do: Fixtures.pending_payment_fixture()
      for %{intent: intent} <- stuck, do: make_due(intent, 900)

      merchant = merchant!()
      fresh = for _n <- 1..2, do: Fixtures.intent_fixture(merchant)
      for intent <- fresh, do: make_due(intent, 600)

      assert {:ok, 2} = Payments.expire_due(DateTime.utc_now(), batch_size: 2)

      for intent <- fresh, do: assert(Fixtures.reload_intent(intent).status == :expired)

      for %{intent: intent} <- stuck,
          do: assert(Fixtures.reload_intent(intent).status == :pending)
    end

    test "an initiated attempt that the provider does not know is not abandoned inside the grace" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)
      attempt = Repo.insert!(%Attempt{payment_intent_id: intent.id, provider: "simulated"})

      # Due by 60 seconds: a confirm that started before the expiry can still reach the provider.
      make_due(intent, 60)

      assert expire_due!() == 0
      assert Fixtures.reload_intent(intent).status == :created
      assert Repo.get!(Attempt, attempt.id).status == :initiated
    end

    test "an initiated attempt whose reply was lost: the provider payment exists, the intent follows it" do
      merchant = merchant!()
      intent = Fixtures.intent_fixture(merchant)
      attempt = Repo.insert!(%Attempt{payment_intent_id: intent.id, provider: "simulated"})
      :ok = Simulated.fault_next_create(attempt.id, :unavailable_after)

      assert Payments.confirm_intent(merchant.id, intent.id, "simulated") ==
               {:error, :provider_unavailable}

      make_due(intent)

      assert expire_due!() == 0

      assert Fixtures.reload_intent(intent).status == :pending
      assert Repo.get!(Attempt, attempt.id).status == :dispatched
      assert Simulated.created_count(attempt.id) == 1
    end

    test "terminal intents are never touched" do
      merchant = merchant!()

      finals =
        for control <- [
              fn id -> Simulated.pay(id, :instant) end,
              fn id -> Simulated.fail(id, "x") end,
              fn id -> Simulated.expire(id) end
            ] do
          %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
          {:ok, _} = control.(attempt.id)
          {:ok, synced} = Payments.sync_attempt(attempt.id)
          make_due(intent)
          synced
        end

      locally_expired = Fixtures.intent_fixture(merchant)
      make_due(locally_expired)
      assert expire_due!() == 1

      all = [locally_expired | finals]
      before = for i <- all, do: {i.id, Fixtures.reload_intent(i), Fixtures.intent_event_types(i)}
      later = DateTime.add(DateTime.utc_now(), 86_400, :second)

      assert expire_due!(later) == 0

      for {id, intent, events} <- before do
        again = Repo.get!(Intent, id)
        assert again.status == intent.status
        assert again.failure_reason == intent.failure_reason
        assert again.updated_at == intent.updated_at
        assert Fixtures.intent_event_types(%Intent{id: id}) == events
      end
    end

    test "a refunded intent is never touched" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, _} = Simulated.pay(attempt.id, :delayed)
      {:ok, _} = Simulated.refund(attempt.id)
      {:ok, %Intent{status: :refunded}} = Payments.sync_attempt(attempt.id)
      make_due(intent)

      assert expire_due!() == 0
      assert Fixtures.reload_intent(intent).status == :refunded
    end
  end

  describe "ExpiryWorker.perform/1" do
    test "expires a due intent and returns :ok" do
      intent = Fixtures.intent_fixture(merchant!())
      make_due(intent)

      assert :ok = perform_job(ExpiryWorker, %{})
      assert Fixtures.reload_intent(intent).status == :expired
    end

    test "self-heals a paid payment with a lost webhook" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, _lost_webhook} = Simulated.pay(attempt.id, :instant)
      make_due(intent)

      assert :ok = perform_job(ExpiryWorker, %{})

      assert Fixtures.reload_intent(intent).status == :final
      assert Fixtures.payment_balances(merchant).merchant.balance_minor == 9_750
      assert Audit.run() == []
    end
  end
end
