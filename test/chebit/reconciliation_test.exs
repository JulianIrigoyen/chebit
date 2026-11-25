defmodule Chebit.ReconciliationTest do
  use Chebit.DataCase, async: false
  use ExUnitProperties

  import Chebit.Fixtures

  alias Chebit.Money
  alias Chebit.Payments
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.Intent
  alias Chebit.Providers.Simulated
  alias Chebit.Reconciliation

  setup do
    Simulated.reset()
    on_exit(fn -> Simulated.set_outage(false) end)
    :ok
  end

  # Creates, confirms and drives one payment to `target` at the simulator, then syncs it.
  defp payment(merchant, amount_minor, currency, target) do
    intent =
      intent_fixture(merchant, %{
        "amount_minor" => amount_minor,
        "currency" => Atom.to_string(currency)
      })

    {:ok, confirmed} = Payments.confirm_intent(merchant.id, intent.id, "simulated")
    attempt = hd(confirmed.attempts)
    drive(attempt.id, target)
    {:ok, synced} = Payments.sync_attempt(attempt.id)
    %{intent: synced, attempt: attempt}
  end

  defp drive(_ref, :pending), do: :ok
  defp drive(ref, :final), do: {:ok, _} = Simulated.pay(ref, :instant)
  defp drive(ref, :paid), do: {:ok, _} = Simulated.pay(ref, :delayed)
  defp drive(ref, :failed), do: {:ok, _} = Simulated.fail(ref, "card_declined")
  defp drive(ref, :expired), do: {:ok, _} = Simulated.expire(ref)

  defp drive(ref, :disputed) do
    drive(ref, :paid)
    {:ok, _} = Simulated.dispute(ref)
  end

  defp drive(ref, :refunded) do
    drive(ref, :paid)
    {:ok, _} = Simulated.refund(ref)
  end

  @states [:final, :paid, :disputed, :refunded, :failed, :expired, :pending]

  # Three merchants, two currencies, each state once. Returns the payments and the fees kept.
  defp mixed_scenario do
    merchants = for bps <- [0, 250, 1_000], do: merchant_fixture(%{fee_bps: bps}).merchant

    rows =
      for {state, index} <- Enum.with_index(@states),
          currency <- [:ARS, :BTC] do
        merchant = Enum.at(merchants, rem(index, 3))
        amount = 10_000 * (index + 1) + if(currency == :BTC, do: 7, else: 0)
        {merchant, amount, currency, state, payment(merchant, amount, currency, state)}
      end

    fees =
      for {merchant, amount, currency, state, _} <- rows,
          state in [:final, :paid, :disputed],
          reduce: %{} do
        acc -> Map.update(acc, currency, kept(merchant, amount), &(&1 + kept(merchant, amount)))
      end

    %{rows: rows, fees: fees}
  end

  defp kept(merchant, amount), do: Money.fee_minor(amount, merchant.fee_bps)

  defp total_of(report, currency), do: Enum.find(report.totals, &(&1.currency == currency))

  defp custody_sum(rows, currency) do
    rows
    |> Enum.filter(fn {_m, _a, c, state, _} ->
      c == currency and state in [:paid, :disputed, :final]
    end)
    |> Enum.map(fn {_m, a, _c, _s, _} -> a end)
    |> Enum.sum()
  end

  describe "run/1" do
    test "a mixed scenario is balanced" do
      %{rows: rows} = mixed_scenario()

      assert {:ok, report} = Reconciliation.run("simulated")
      assert report.provider == "simulated"
      assert report.balanced?
      assert report.discrepancies == []
      assert report.matched == length(rows)
      assert Enum.map(report.totals, & &1.currency) == [:ARS, :BTC]
      assert Enum.all?(report.totals, &(&1.difference_minor == 0))

      for currency <- [:ARS, :BTC] do
        total = total_of(report, currency)
        assert total.provider_minor == custody_sum(rows, currency)
        assert total.ledger_minor == total.provider_minor
      end
    end

    test "an empty provider and an empty ledger give an empty balanced report" do
      assert {:ok, %{matched: 0, discrepancies: [], totals: [], balanced?: true}} =
               Reconciliation.run("simulated")
    end

    test "reports :missing_in_ledger for a payment that no attempt owns" do
      reference = Ecto.UUID.generate()

      {:ok, _} =
        Simulated.create_payment(%{
          reference: reference,
          amount_minor: 5_000,
          currency: :ARS,
          description: nil,
          expires_at: DateTime.utc_now()
        })

      assert {:ok, report} = Reconciliation.run("simulated")

      assert [%{kind: :missing_in_ledger, reference: ^reference, detail: detail}] =
               report.discrepancies

      assert detail.provider_status == :pending
      assert detail.provider_amount_minor == 5_000
      assert report.matched == 0
      refute report.balanced?
    end

    test "reports :missing_at_provider for a dispatched attempt that the provider lost" do
      %{attempt: attempt} = pending_payment_fixture()
      Simulated.reset()

      assert {:ok, report} = Reconciliation.run("simulated")

      assert [
               %{
                 kind: :missing_at_provider,
                 reference: reference,
                 detail: %{intent_status: :pending}
               }
             ] =
               report.discrepancies

      assert reference == attempt.id
      refute report.balanced?
    end

    test "reports :amount_mismatch when the intent amount differs" do
      %{intent: intent, attempt: attempt} = pending_payment_fixture(amount_minor: 10_000)
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [amount_minor: 9_000])

      assert {:ok, report} = Reconciliation.run("simulated")

      assert [%{kind: :amount_mismatch, reference: reference, detail: detail}] =
               report.discrepancies

      assert reference == attempt.id
      assert detail.provider_amount_minor == 10_000
      assert detail.ledger_amount_minor == 9_000
      assert report.matched == 0
    end

    test "reports :status_mismatch when the provider is ahead, and the totals differ" do
      %{attempt: attempt} = pending_payment_fixture(amount_minor: 12_000)
      {:ok, _} = Simulated.pay(attempt.id, :delayed)

      assert {:ok, report} = Reconciliation.run("simulated")

      assert [
               %{
                 kind: :status_mismatch,
                 detail: %{provider_status: :paid, intent_status: :pending}
               }
             ] =
               report.discrepancies

      assert total_of(report, :ARS).difference_minor == 12_000
      refute report.balanced?
    end

    test "a lost reply is a :status_mismatch until the second confirm" do
      %{merchant: merchant} = merchant_fixture(%{fee_bps: 100})
      intent = intent_fixture(merchant)
      attempt = Repo.insert!(%Attempt{payment_intent_id: intent.id, provider: "simulated"})
      :ok = Simulated.fault_next_create(attempt.id, :unavailable_after)

      assert {:error, :provider_unavailable} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert {:ok, report} = Reconciliation.run("simulated")
      assert [%{kind: :status_mismatch, reference: reference}] = report.discrepancies
      assert reference == attempt.id

      assert {:ok, %Intent{status: :pending}} =
               Payments.confirm_intent(merchant.id, intent.id, "simulated")

      assert {:ok, %{balanced?: true, discrepancies: [], matched: 1}} =
               Reconciliation.run("simulated")
    end

    test "a failed attempt with a payment at the provider is a :status_mismatch" do
      %{attempt: attempt} = pending_payment_fixture()
      Repo.update_all(from(a in Attempt, where: a.id == ^attempt.id), set: [status: :failed])

      assert {:ok, report} = Reconciliation.run("simulated")

      assert [%{kind: :status_mismatch, detail: %{attempt_status: :failed}}] =
               report.discrepancies
    end
  end

  describe "run/1 with rejected input" do
    test "an unknown provider" do
      assert {:error, :unknown_provider} = Reconciliation.run("nope")
    end

    test "a value that is not a string" do
      for input <- [nil, :simulated, 42, %{}, ["simulated"]] do
        assert {:error, :unknown_provider} = Reconciliation.run(input)
      end
    end

    test "an outage" do
      :ok = Simulated.set_outage(true)
      assert {:error, :provider_unavailable} = Reconciliation.run("simulated")
    end
  end

  describe "run_all/0" do
    test "returns an empty list when everything matches" do
      mixed_scenario()
      assert {:ok, []} = Reconciliation.run_all()
    end

    test "names the provider that has a discrepancy" do
      pending_payment_fixture()
      Simulated.reset()
      assert {:ok, ["simulated"]} = Reconciliation.run_all()
    end

    test "names the provider that is unavailable" do
      :ok = Simulated.set_outage(true)
      assert {:ok, ["simulated"]} = Reconciliation.run_all()
    end
  end

  describe "coverage/0" do
    test "a sum of balances above the bigint range does not raise" do
      big = 5_000_000_000_000_000_000
      for _n <- 1..2, do: Chebit.Fixtures.fund(Chebit.Fixtures.customer_account(:ARS), big)

      assert {:ok, [%{currency: :ARS, custody_minor: 0, owed_minor: owed, covered?: false}]} =
               Reconciliation.coverage()

      assert owed == 2 * big
    end

    test "custody covers what is owed, by the fees kept" do
      %{fees: fees} = mixed_scenario()

      assert {:ok, coverage} = Reconciliation.coverage()
      assert Enum.map(coverage, & &1.currency) == [:ARS, :BTC]

      for row <- coverage do
        assert row.covered?
        assert row.custody_minor >= row.owed_minor
        assert row.custody_minor - row.owed_minor == Map.fetch!(fees, row.currency)
      end
    end

    test "is not covered when a payment disappears at the provider" do
      %{merchant: merchant} = merchant_fixture(%{fee_bps: 250})
      payment(merchant, 20_000, :ARS, :final)
      Simulated.reset()

      assert {:ok, [%{currency: :ARS, custody_minor: 0, covered?: false} = row]} =
               Reconciliation.coverage()

      assert row.owed_minor == 19_500
    end

    test "fails during an outage" do
      :ok = Simulated.set_outage(true)
      assert {:error, :provider_unavailable} = Reconciliation.coverage()
    end
  end

  describe "properties" do
    property "any set of payments driven to any state reconciles to zero and is covered" do
      payment_gen =
        tuple({
          integer(1..2_000_000),
          member_of([:ARS, :BTC, :USD]),
          member_of(@states),
          integer(0..2_000)
        })

      # The simulator and the database both keep what earlier runs of this test made.
      check all(payments <- list_of(payment_gen, max_length: 6), max_runs: 25) do
        for {amount, currency, state, fee_bps} <- payments do
          %{merchant: merchant} = merchant_fixture(%{fee_bps: fee_bps})
          payment(merchant, amount, currency, state)
        end

        assert {:ok, %{balanced?: true, discrepancies: []} = report} =
                 Reconciliation.run("simulated")

        assert Enum.all?(report.totals, &(&1.difference_minor == 0))
        assert {:ok, coverage} = Reconciliation.coverage()
        assert Enum.all?(coverage, & &1.covered?)
      end
    end
  end
end
