defmodule Chebit.Webhooks.OutageTest do
  # The outage switch is global in the simulator: no other test may run while it is on.
  use Chebit.DataCase, async: false
  use Oban.Testing, repo: Chebit.Repo

  alias Chebit.Fixtures
  alias Chebit.Payments
  alias Chebit.Providers.Simulated
  alias Chebit.Webhooks
  alias Chebit.Webhooks.ProcessWorker
  alias Chebit.Webhooks.ProviderEvent

  setup do
    on_exit(fn -> Simulated.set_outage(false) end)
    :ok
  end

  defp stored(%{body: body, headers: headers}) do
    {:ok, :accepted} = Webhooks.ingest("simulated", body, headers)
    %{"id" => event_id} = Jason.decode!(body)
    Repo.get_by!(ProviderEvent, provider: "simulated", event_id: event_id)
  end

  test "process/1 during an outage keeps the event received; the worker asks for a retry; later it succeeds" do
    %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
    {:ok, delivery} = Simulated.pay(attempt.id, :delayed)
    row = stored(delivery)

    :ok = Simulated.set_outage(true)

    assert Webhooks.process(row.id) == {:error, :provider_unavailable}
    assert Repo.get!(ProviderEvent, row.id).status == :received
    assert Repo.get!(ProviderEvent, row.id).processed_at == nil

    assert perform_job(ProcessWorker, %{provider_event_id: row.id}) ==
             {:error, :provider_unavailable}

    assert Repo.get!(ProviderEvent, row.id).status == :received
    assert Fixtures.reload_intent(intent).status == :pending

    :ok = Simulated.set_outage(false)

    assert Webhooks.process(row.id) == :ok
    processed = Repo.get!(ProviderEvent, row.id)
    assert processed.status == :processed
    assert processed.processed_at != nil
    assert Fixtures.reload_intent(intent).status == :paid
  end

  test "the worker succeeds after the outage on the same event" do
    %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
    {:ok, delivery} = Simulated.pay(attempt.id, :instant)
    row = stored(delivery)

    :ok = Simulated.set_outage(true)

    assert {:error, :provider_unavailable} =
             perform_job(ProcessWorker, %{provider_event_id: row.id})

    :ok = Simulated.set_outage(false)

    assert :ok = perform_job(ProcessWorker, %{provider_event_id: row.id})
    assert Fixtures.reload_intent(intent).status == :final
  end

  test "sync_attempt/1 during an outage gives :provider_unavailable and changes nothing" do
    %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
    {:ok, _} = Simulated.pay(attempt.id, :delayed)
    events = Fixtures.intent_event_types(intent)

    :ok = Simulated.set_outage(true)

    assert Payments.sync_attempt(attempt.id) == {:error, :provider_unavailable}
    assert Fixtures.reload_intent(intent).status == :pending
    assert Fixtures.intent_event_types(intent) == events
  end

  test "expire_due/1 during an outage leaves a due pending intent untouched" do
    %{intent: intent} = Fixtures.pending_payment_fixture()
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(from(i in Chebit.Payments.Intent, where: i.id == ^intent.id),
      set: [expires_at: past]
    )

    events = Fixtures.intent_event_types(intent)
    :ok = Simulated.set_outage(true)

    assert Payments.expire_due(DateTime.utc_now()) == {:ok, 0}
    assert Fixtures.reload_intent(intent).status == :pending
    assert Fixtures.intent_event_types(intent) == events

    :ok = Simulated.set_outage(false)
    assert Payments.expire_due(DateTime.utc_now()) == {:ok, 0}
    assert Fixtures.reload_intent(intent).status == :pending
  end
end
