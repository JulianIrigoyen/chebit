defmodule Chebit.WebhooksTest do
  use Chebit.DataCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  alias Chebit.Fixtures
  alias Chebit.Ledger.Audit
  alias Chebit.Ledger.Transaction
  alias Chebit.Providers.Simulated
  alias Chebit.Webhooks
  alias Chebit.Webhooks.ProcessWorker
  alias Chebit.Webhooks.ProviderEvent

  defp secret, do: Application.fetch_env!(:chebit, Simulated)[:webhook_secret]

  defp sign(body),
    do: :hmac |> :crypto.mac(:sha256, secret(), body) |> Base.encode16(case: :lower)

  # A validly signed delivery that the simulator never produced.
  defp forged(reference) do
    body =
      Jason.encode!(%{
        "id" => "evt_forged_#{System.unique_integer([:positive])}",
        "type" => "payment.updated",
        "reference" => reference,
        "external_id" => "sim_forged"
      })

    %{body: body, headers: [{"x-simulated-signature", sign(body)}]}
  end

  defp ingest!(%{body: body, headers: headers}) do
    assert {:ok, :accepted} = Webhooks.ingest("simulated", body, headers)
    %{"id" => event_id} = Jason.decode!(body)
    Repo.get_by!(ProviderEvent, provider: "simulated", event_id: event_id)
  end

  defp event_rows, do: Repo.aggregate(ProviderEvent, :count)
  defp process_jobs, do: all_enqueued(worker: ProcessWorker)

  describe "ingest/3" do
    test "stores the exact body and the reference, and enqueues one job" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt.id, :delayed)

      assert Webhooks.ingest("simulated", body, headers) == {:ok, :accepted}

      assert [%ProviderEvent{} = row] = Repo.all(ProviderEvent)
      assert row.raw_body == body
      assert row.reference == attempt.id
      assert row.provider == "simulated"
      assert row.status == :received
      assert row.processed_at == nil
      assert %{"id" => event_id} = Jason.decode!(body)
      assert row.event_id == event_id
      assert [job] = process_jobs()
      assert job.args == %{"provider_event_id" => row.id}
    end

    test "the same delivery again is a duplicate: one row, one job" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt.id, :delayed)

      assert Webhooks.ingest("simulated", body, headers) == {:ok, :accepted}
      assert Webhooks.ingest("simulated", body, headers) == {:ok, :duplicate}
      assert Webhooks.ingest("simulated", body, headers) == {:ok, :duplicate}

      assert event_rows() == 1
      assert length(process_jobs()) == 1
    end

    test "two different events for one payment are two rows and two jobs" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, first} = Simulated.pay(attempt.id, :delayed)
      {:ok, second} = Simulated.finalize(attempt.id)

      ingest!(first)
      ingest!(second)

      assert event_rows() == 2
      assert length(process_jobs()) == 2
    end

    test "a tampered body gives :invalid_signature and stores nothing" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt.id, :delayed)

      assert Webhooks.ingest("simulated", body <> " ", headers) == {:error, :invalid_signature}
      assert event_rows() == 0
      assert process_jobs() == []
    end

    test "a tampered signature gives :invalid_signature and stores nothing" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, %{body: body, headers: [{name, signature}]}} = Simulated.pay(attempt.id, :delayed)

      flipped = String.reverse(signature)
      assert Webhooks.ingest("simulated", body, [{name, flipped}]) == {:error, :invalid_signature}
      assert Webhooks.ingest("simulated", body, [{name, ""}]) == {:error, :invalid_signature}
      assert event_rows() == 0
      assert process_jobs() == []
    end

    test "no signature header gives :invalid_signature and stores nothing" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, %{body: body}} = Simulated.pay(attempt.id, :delayed)

      assert Webhooks.ingest("simulated", body, []) == {:error, :invalid_signature}

      assert Webhooks.ingest("simulated", body, [{"x-other", "abc"}]) ==
               {:error, :invalid_signature}

      assert event_rows() == 0
    end

    test "a signature made with another secret gives :invalid_signature" do
      body = Jason.encode!(%{"id" => "e1", "reference" => Ecto.UUID.generate()})

      signature =
        :hmac |> :crypto.mac(:sha256, "other-secret", body) |> Base.encode16(case: :lower)

      assert Webhooks.ingest("simulated", body, [{"x-simulated-signature", signature}]) ==
               {:error, :invalid_signature}

      assert event_rows() == 0
    end

    test "a signed body without id and reference gives :malformed and stores nothing" do
      for body <- [
            "not json",
            ~s({"id": "e1"}),
            ~s({"reference": "r"}),
            ~s({"id": 1, "reference": 2}),
            "[]"
          ] do
        assert Webhooks.ingest("simulated", body, [{"x-simulated-signature", sign(body)}]) ==
                 {:error, :malformed}
      end

      assert event_rows() == 0
    end

    test "an unknown provider and a non-binary provider give :unknown_provider" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt.id, :delayed)

      assert Webhooks.ingest("stripe", body, headers) == {:error, :unknown_provider}
      assert Webhooks.ingest(:simulated, body, headers) == {:error, :unknown_provider}
      assert Webhooks.ingest(nil, body, headers) == {:error, :unknown_provider}
      assert Webhooks.ingest(42, body, headers) == {:error, :unknown_provider}
      assert event_rows() == 0
    end

    test "a non-binary body and odd headers do not raise" do
      assert Webhooks.ingest("simulated", nil, []) == {:error, :invalid_signature}
      assert Webhooks.ingest("simulated", 12, []) == {:error, :invalid_signature}
      assert Webhooks.ingest("simulated", "x", nil) == {:error, :invalid_signature}

      assert Webhooks.ingest("simulated", "x", [{"x-simulated-signature", 5}]) ==
               {:error, :invalid_signature}
    end
  end

  describe "process/1" do
    test "syncs the payment, marks the event processed and moves the intent" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, delivery} = Simulated.pay(attempt.id, :delayed)
      row = ingest!(delivery)

      assert Webhooks.process(row.id) == :ok

      processed = Repo.get!(ProviderEvent, row.id)
      assert processed.status == :processed
      assert processed.processed_at != nil
      assert processed.error == nil
      assert Fixtures.reload_intent(intent).status == :paid
      assert Fixtures.payment_balances(merchant).merchant.balance_minor == 9_750
      assert Audit.run() == []
    end

    test "a second process of the same event returns :ok and changes nothing" do
      %{merchant: merchant, intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, delivery} = Simulated.pay(attempt.id, :delayed)
      row = ingest!(delivery)

      assert Webhooks.process(row.id) == :ok
      first = Repo.get!(ProviderEvent, row.id)
      events = Fixtures.intent_event_types(intent)
      tx_count = Repo.aggregate(Transaction, :count)
      balances = Fixtures.payment_balances(merchant)

      assert Webhooks.process(row.id) == :ok

      assert Repo.get!(ProviderEvent, row.id) == first
      assert Fixtures.intent_event_types(intent) == events
      assert Repo.aggregate(Transaction, :count) == tx_count
      assert Fixtures.payment_balances(merchant) == balances
    end

    test "events that arrive out of order: the late one changes nothing" do
      %{merchant: merchant, intent: intent, attempt: attempt} =
        Fixtures.pending_payment_fixture(fee_bps: 250)

      {:ok, first} = Simulated.pay(attempt.id, :delayed)
      {:ok, second} = Simulated.finalize(attempt.id)
      first_row = ingest!(first)
      second_row = ingest!(second)

      assert Webhooks.process(second_row.id) == :ok
      assert Fixtures.reload_intent(intent).status == :final

      events = Fixtures.intent_event_types(intent)
      tx_count = Repo.aggregate(Transaction, :count)
      balances = Fixtures.payment_balances(merchant)

      assert Webhooks.process(first_row.id) == :ok

      assert Fixtures.reload_intent(intent).status == :final
      assert Repo.get!(ProviderEvent, first_row.id).status == :processed
      assert Fixtures.intent_event_types(intent) == events

      assert events ==
               [
                 "payment_intent.created",
                 "payment_intent.pending",
                 "payment_intent.paid",
                 "payment_intent.final"
               ]

      assert Repo.aggregate(Transaction, :count) == tx_count
      assert Fixtures.payment_balances(merchant) == balances
      assert %{balance_minor: 9_750, held_minor: 0} = balances.merchant
      assert Audit.run() == []
    end

    test "a forged, validly signed event for an unknown reference is rejected" do
      row = ingest!(forged(Ecto.UUID.generate()))

      assert Webhooks.process(row.id) == {:error, {:rejected, :not_found}}

      failed = Repo.get!(ProviderEvent, row.id)
      assert failed.status == :failed
      assert failed.error == "not_found"
      assert failed.processed_at != nil
      assert Repo.aggregate(Transaction, :count) == 0
    end

    test "a forged event whose reference is not a uuid is rejected without a raise" do
      row = ingest!(forged("not-a-uuid"))

      assert Webhooks.process(row.id) == {:error, {:rejected, :not_found}}
      assert Repo.get!(ProviderEvent, row.id).status == :failed
    end

    test "a failed event processed again returns :ok and stays failed" do
      row = ingest!(forged(Ecto.UUID.generate()))
      assert {:error, {:rejected, :not_found}} = Webhooks.process(row.id)

      assert Webhooks.process(row.id) == :ok
      assert Repo.get!(ProviderEvent, row.id).status == :failed
    end

    test "an event for a payment that cannot move is rejected and changes nothing" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()

      Repo.update_all(from(i in Chebit.Payments.Intent, where: i.id == ^intent.id),
        set: [status: :expired]
      )

      {:ok, delivery} = Simulated.pay(attempt.id, :instant)
      row = ingest!(delivery)

      assert Webhooks.process(row.id) == {:error, {:rejected, :invalid_transition}}
      assert Repo.get!(ProviderEvent, row.id).error == "invalid_transition"
      assert Fixtures.reload_intent(intent).status == :expired
    end

    test "gives :event_not_found for an unknown id and for a non-integer" do
      assert Webhooks.process(0) == {:error, :event_not_found}
      assert Webhooks.process(999_999_999) == {:error, :event_not_found}
      assert Webhooks.process("1") == {:error, :event_not_found}
      assert Webhooks.process(nil) == {:error, :event_not_found}
      assert Webhooks.process(1.0) == {:error, :event_not_found}
      assert Webhooks.process(%{}) == {:error, :event_not_found}
    end
  end
end
