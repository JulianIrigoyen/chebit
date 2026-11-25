defmodule Chebit.Webhooks.ProcessWorkerTest do
  use Chebit.DataCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  alias Chebit.Fixtures
  alias Chebit.Providers.Simulated
  alias Chebit.Webhooks
  alias Chebit.Webhooks.ProcessWorker
  alias Chebit.Webhooks.ProviderEvent

  defp stored(%{body: body, headers: headers}) do
    {:ok, :accepted} = Webhooks.ingest("simulated", body, headers)
    %{"id" => event_id} = Jason.decode!(body)
    Repo.get_by!(ProviderEvent, provider: "simulated", event_id: event_id)
  end

  describe "perform/1" do
    test "returns :ok for a good event and moves the intent" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, delivery} = Simulated.pay(attempt.id, :delayed)
      row = stored(delivery)

      assert :ok = perform_job(ProcessWorker, %{provider_event_id: row.id})
      assert Fixtures.reload_intent(intent).status == :paid
      assert Repo.get!(ProviderEvent, row.id).status == :processed
    end

    test "returns :ok when the event is already processed" do
      %{attempt: attempt} = Fixtures.pending_payment_fixture()
      {:ok, delivery} = Simulated.pay(attempt.id, :delayed)
      row = stored(delivery)

      assert :ok = perform_job(ProcessWorker, %{provider_event_id: row.id})
      assert :ok = perform_job(ProcessWorker, %{provider_event_id: row.id})
    end

    test "cancels a rejected event" do
      body =
        Jason.encode!(%{
          "id" => "evt_forged_#{System.unique_integer([:positive])}",
          "reference" => Ecto.UUID.generate()
        })

      secret = Application.fetch_env!(:chebit, Simulated)[:webhook_secret]
      sig = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
      row = stored(%{body: body, headers: [{"x-simulated-signature", sig}]})

      assert {:cancel, _reason} = perform_job(ProcessWorker, %{provider_event_id: row.id})
      assert Repo.get!(ProviderEvent, row.id).status == :failed
    end

    test "cancels an unknown event id" do
      assert {:cancel, _reason} = perform_job(ProcessWorker, %{provider_event_id: 999_999_999})
    end

    test "cancels bad args" do
      assert {:cancel, _} = perform_job(ProcessWorker, %{})
      assert {:cancel, _} = perform_job(ProcessWorker, %{"other" => 1})
      assert {:cancel, _} = perform_job(ProcessWorker, %{provider_event_id: "abc"})
      assert {:cancel, _} = perform_job(ProcessWorker, %{provider_event_id: nil})
    end
  end
end
