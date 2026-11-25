defmodule Chebit.Payments.LostPaymentTest do
  # `Simulated.reset/0` forgets each payment of the simulator, so this file runs alone.
  use Chebit.DataCase, async: false

  alias Chebit.Fixtures
  alias Chebit.Payments
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.Intent
  alias Chebit.Providers.Simulated
  alias Chebit.Reconciliation

  setup do
    Simulated.reset()
    on_exit(&Simulated.reset/0)
  end

  describe "expire_due/2" do
    # "Not found" can be a provider that lags behind its own write. A payment that the
    # provider confirmed can be live, so the expiry job must leave it to reconciliation.
    test "never abandons an attempt that the provider confirmed, even when the provider lost it" do
      %{intent: intent, attempt: attempt} = Fixtures.pending_payment_fixture()
      Simulated.reset()

      past = DateTime.add(DateTime.utc_now(), -600, :second)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [expires_at: past])

      assert {:ok, 0} = Payments.expire_due(DateTime.utc_now())
      assert Fixtures.reload_intent(intent).status == :pending
      assert Repo.get!(Attempt, attempt.id).status == :dispatched

      assert {:ok, %{balanced?: false, discrepancies: [%{kind: :missing_at_provider}]}} =
               Reconciliation.run("simulated")
    end
  end
end
