defmodule Chebit.Reconciliation.WorkerTest do
  use Chebit.DataCase, async: false
  use Oban.Testing, repo: Chebit.Repo

  import Chebit.Fixtures
  import ExUnit.CaptureLog

  alias Chebit.Providers.Simulated
  alias Chebit.Reconciliation.Worker

  setup do
    Simulated.reset()
    on_exit(fn -> Simulated.set_outage(false) end)
    :ok
  end

  describe "perform/1" do
    test "returns :ok when each provider is balanced" do
      pending_payment_fixture()
      assert :ok = perform_job(Worker, %{})
    end

    test "returns an error and logs when a payment does not match" do
      pending_payment_fixture()
      Simulated.reset()

      log =
        capture_log(fn ->
          assert {:error, :reconciliation_mismatch} = perform_job(Worker, %{})
        end)

      assert log =~ "reconciliation does not match for: simulated"
    end

    test "returns an error when the provider is unavailable" do
      :ok = Simulated.set_outage(true)

      capture_log(fn ->
        assert {:error, :reconciliation_mismatch} = perform_job(Worker, %{})
      end)
    end
  end
end
