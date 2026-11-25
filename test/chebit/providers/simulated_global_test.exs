defmodule Chebit.Providers.SimulatedGlobalTest do
  # These tests read or change global simulator state, so they run alone.
  use ExUnit.Case, async: false

  alias Chebit.Providers.Simulated

  setup do
    Simulated.reset()

    on_exit(fn ->
      Simulated.set_outage(false)
      Simulated.reset()
    end)
  end

  defp create!(reference) do
    {:ok, payment} =
      Simulated.create_payment(%{
        reference: reference,
        amount_minor: 100,
        currency: :USD,
        description: nil,
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      })

    payment
  end

  describe "list_payments/0" do
    test "is empty after a reset" do
      assert Simulated.list_payments() == {:ok, []}
    end

    test "lists each payment once, in its current state" do
      a = create!(Ecto.UUID.generate())
      b = create!(Ecto.UUID.generate())
      create!(a.reference)
      {:ok, _} = Simulated.pay(b.reference, :delayed)

      assert {:ok, payments} = Simulated.list_payments()

      assert payments |> Enum.map(& &1.reference) |> Enum.sort() ==
               Enum.sort([a.reference, b.reference])

      assert Enum.find(payments, &(&1.reference == a.reference)).status == :pending
      assert Enum.find(payments, &(&1.reference == b.reference)).status == :paid
    end
  end

  describe "set_outage/1" do
    test "makes fetch_payment/1 and list_payments/0 return :unavailable" do
      payment = create!(Ecto.UUID.generate())
      assert :ok = Simulated.set_outage(true)

      assert Simulated.fetch_payment(payment.reference) == {:error, :unavailable}
      assert Simulated.fetch_payment("missing") == {:error, :unavailable}
      assert Simulated.list_payments() == {:error, :unavailable}
    end

    test "does not affect create_payment/1, the controls or created_count/1" do
      :ok = Simulated.set_outage(true)
      reference = Ecto.UUID.generate()
      payment = create!(reference)

      assert {:ok, _} = Simulated.pay(reference, :delayed)
      assert Simulated.created_count(reference) == 1
      assert payment.reference == reference
    end

    test "false restores reads" do
      payment = create!(Ecto.UUID.generate())
      :ok = Simulated.set_outage(true)
      :ok = Simulated.set_outage(false)

      assert {:ok, ^payment} = Simulated.fetch_payment(payment.reference)
      assert {:ok, [^payment]} = Simulated.list_payments()
    end
  end

  describe "reset/0" do
    test "clears payments, counts, faults and the outage" do
      reference = Ecto.UUID.generate()
      create!(reference)
      other = Ecto.UUID.generate()
      :ok = Simulated.fault_next_create(other, :decline)
      :ok = Simulated.set_outage(true)

      assert :ok = Simulated.reset()

      assert Simulated.list_payments() == {:ok, []}
      assert Simulated.fetch_payment(reference) == {:error, :not_found}
      assert Simulated.created_count(reference) == 0

      assert {:ok, _} =
               Simulated.create_payment(%{
                 reference: other,
                 amount_minor: 1,
                 currency: :ARS,
                 description: nil,
                 expires_at: DateTime.utc_now()
               })
    end
  end
end
