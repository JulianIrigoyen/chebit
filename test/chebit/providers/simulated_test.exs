defmodule Chebit.Providers.SimulatedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chebit.Providers.Simulated

  @payment_keys [
    :amount_minor,
    :currency,
    :external_id,
    :failure_reason,
    :payment_data,
    :reference,
    :status
  ]

  defp request(reference \\ Ecto.UUID.generate()) do
    %{
      reference: reference,
      amount_minor: 1_500,
      currency: :ARS,
      description: "test",
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    }
  end

  defp create!(reference \\ Ecto.UUID.generate()) do
    {:ok, payment} = Simulated.create_payment(request(reference))
    payment
  end

  defp status(reference) do
    {:ok, payment} = Simulated.fetch_payment(reference)
    payment.status
  end

  defp event(%{body: body}), do: Jason.decode!(body)

  describe "create_payment/1" do
    test "creates a pending payment with exactly the payment keys" do
      reference = Ecto.UUID.generate()
      payment = create!(reference)

      assert payment |> Map.keys() |> Enum.sort() == @payment_keys
      assert payment.status == :pending
      assert payment.reference == reference
      assert payment.amount_minor == 1_500
      assert payment.currency == :ARS
      assert payment.failure_reason == nil
      assert "sim_" <> hex = payment.external_id
      assert hex =~ ~r/^[0-9a-f]+$/
      assert payment.payment_data == %{"qr" => "simulated:" <> payment.external_id}
    end

    test "is idempotent on the reference" do
      reference = Ecto.UUID.generate()
      first = create!(reference)

      for _ <- 1..5, do: assert(create!(reference) == first)

      assert Simulated.created_count(reference) == 1
    end

    test "a second call returns the stored payment unchanged after a status move" do
      reference = Ecto.UUID.generate()
      first = create!(reference)
      {:ok, _} = Simulated.pay(reference, :delayed)

      again = create!(reference)
      assert again.external_id == first.external_id
      assert again.status == :paid
      assert Simulated.created_count(reference) == 1
    end

    test "different references give different external ids" do
      refute create!().external_id == create!().external_id
    end
  end

  describe "fault_next_create/2" do
    test ":decline returns :declined and creates nothing" do
      reference = Ecto.UUID.generate()
      :ok = Simulated.fault_next_create(reference, :decline)

      assert Simulated.create_payment(request(reference)) == {:error, :declined}
      assert Simulated.created_count(reference) == 0
      assert Simulated.fetch_payment(reference) == {:error, :not_found}
    end

    test ":unavailable_before returns :unavailable and creates nothing" do
      reference = Ecto.UUID.generate()
      :ok = Simulated.fault_next_create(reference, :unavailable_before)

      assert Simulated.create_payment(request(reference)) == {:error, :unavailable}
      assert Simulated.created_count(reference) == 0
      assert Simulated.fetch_payment(reference) == {:error, :not_found}
    end

    test ":unavailable_after creates the payment, and a retry gets it once (invariant 5)" do
      reference = Ecto.UUID.generate()
      :ok = Simulated.fault_next_create(reference, :unavailable_after)

      assert Simulated.create_payment(request(reference)) == {:error, :unavailable}
      assert Simulated.created_count(reference) == 1

      assert {:ok, payment} = Simulated.create_payment(request(reference))
      assert payment.reference == reference
      assert Simulated.created_count(reference) == 1
      assert Simulated.fetch_payment(reference) == {:ok, payment}
    end

    test "a fault applies once, then clears" do
      reference = Ecto.UUID.generate()
      :ok = Simulated.fault_next_create(reference, :decline)

      assert {:error, :declined} = Simulated.create_payment(request(reference))
      assert {:ok, _} = Simulated.create_payment(request(reference))
      assert Simulated.created_count(reference) == 1
    end

    test "a fault on one reference does not touch another" do
      faulty = Ecto.UUID.generate()
      :ok = Simulated.fault_next_create(faulty, :decline)

      assert {:ok, _} = Simulated.create_payment(request())
      assert {:error, :declined} = Simulated.create_payment(request(faulty))
    end
  end

  describe "fetch_payment/1" do
    test "returns the payment" do
      payment = create!()
      assert Simulated.fetch_payment(payment.reference) == {:ok, payment}
    end

    test "returns :not_found for an unknown reference" do
      assert Simulated.fetch_payment(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "created_count/1" do
    test "is 0 for an unknown reference" do
      assert Simulated.created_count(Ecto.UUID.generate()) == 0
    end
  end

  describe "pay/2" do
    test "instant finality moves pending to final" do
      reference = create!().reference
      assert {:ok, %{body: _, headers: _}} = Simulated.pay(reference)
      assert status(reference) == :final
    end

    test "delayed finality moves pending to paid" do
      reference = create!().reference
      assert {:ok, _} = Simulated.pay(reference, :delayed)
      assert status(reference) == :paid
    end

    test "is refused outside pending" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)

      assert Simulated.pay(reference) == {:error, :invalid_state}
      assert Simulated.pay(reference, :delayed) == {:error, :invalid_state}
      assert status(reference) == :paid
    end
  end

  describe "finalize/1" do
    test "moves paid to final" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)
      assert {:ok, _} = Simulated.finalize(reference)
      assert status(reference) == :final
    end

    test "moves disputed to final" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)
      {:ok, _} = Simulated.dispute(reference)
      assert {:ok, _} = Simulated.finalize(reference)
      assert status(reference) == :final
    end

    test "is refused from pending and from final" do
      reference = create!().reference
      assert Simulated.finalize(reference) == {:error, :invalid_state}
      {:ok, _} = Simulated.pay(reference)
      assert Simulated.finalize(reference) == {:error, :invalid_state}
    end
  end

  describe "fail/2" do
    test "moves pending to failed and stores the reason" do
      reference = create!().reference
      assert {:ok, _} = Simulated.fail(reference, "insufficient_funds")

      assert {:ok, payment} = Simulated.fetch_payment(reference)
      assert payment.status == :failed
      assert payment.failure_reason == "insufficient_funds"
    end

    test "is refused outside pending" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)
      assert Simulated.fail(reference, "x") == {:error, :invalid_state}
      assert status(reference) == :paid
    end
  end

  describe "expire/1" do
    test "moves pending to expired" do
      reference = create!().reference
      assert {:ok, _} = Simulated.expire(reference)
      assert status(reference) == :expired
    end

    test "is refused outside pending" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference)
      assert Simulated.expire(reference) == {:error, :invalid_state}
    end
  end

  describe "dispute/1" do
    test "moves paid to disputed" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)
      assert {:ok, _} = Simulated.dispute(reference)
      assert status(reference) == :disputed
    end

    test "is refused from pending, disputed and final" do
      reference = create!().reference
      assert Simulated.dispute(reference) == {:error, :invalid_state}
      {:ok, _} = Simulated.pay(reference, :delayed)
      {:ok, _} = Simulated.dispute(reference)
      assert Simulated.dispute(reference) == {:error, :invalid_state}

      other = create!().reference
      {:ok, _} = Simulated.pay(other)
      assert Simulated.dispute(other) == {:error, :invalid_state}
    end
  end

  describe "refund/1" do
    test "moves paid to refunded" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)
      assert {:ok, _} = Simulated.refund(reference)
      assert status(reference) == :refunded
    end

    test "moves disputed to refunded" do
      reference = create!().reference
      {:ok, _} = Simulated.pay(reference, :delayed)
      {:ok, _} = Simulated.dispute(reference)
      assert {:ok, _} = Simulated.refund(reference)
      assert status(reference) == :refunded
    end

    test "is refused from pending, final and refunded" do
      reference = create!().reference
      assert Simulated.refund(reference) == {:error, :invalid_state}

      other = create!().reference
      {:ok, _} = Simulated.pay(other)
      assert Simulated.refund(other) == {:error, :invalid_state}

      third = create!().reference
      {:ok, _} = Simulated.pay(third, :delayed)
      {:ok, _} = Simulated.refund(third)
      assert Simulated.refund(third) == {:error, :invalid_state}
    end
  end

  describe "controls on an unknown reference" do
    test "return :not_found" do
      reference = Ecto.UUID.generate()

      assert Simulated.pay(reference) == {:error, :not_found}
      assert Simulated.pay(reference, :delayed) == {:error, :not_found}
      assert Simulated.finalize(reference) == {:error, :not_found}
      assert Simulated.fail(reference, "x") == {:error, :not_found}
      assert Simulated.expire(reference) == {:error, :not_found}
      assert Simulated.dispute(reference) == {:error, :not_found}
      assert Simulated.refund(reference) == {:error, :not_found}
      assert Simulated.webhook_for(reference) == {:error, :not_found}
    end
  end

  describe "terminal payments" do
    test "accept no further move" do
      reference = create!().reference
      {:ok, _} = Simulated.fail(reference, "x")

      for result <- [
            Simulated.pay(reference),
            Simulated.finalize(reference),
            Simulated.fail(reference, "y"),
            Simulated.expire(reference),
            Simulated.dispute(reference),
            Simulated.refund(reference)
          ] do
        assert result == {:error, :invalid_state}
      end

      assert status(reference) == :failed
    end
  end

  describe "webhooks from controls and webhook_for/1" do
    test "a control returns a signed webhook in the documented format" do
      payment = create!()

      assert {:ok, %{body: body, headers: [{"x-simulated-signature", sig}]}} =
               Simulated.pay(payment.reference)

      assert %{
               "id" => "evt_" <> _,
               "type" => "payment.updated",
               "reference" => reference,
               "external_id" => external_id
             } = Jason.decode!(body)

      assert reference == payment.reference
      assert external_id == payment.external_id
      assert sig =~ ~r/^[0-9a-f]{64}$/
    end

    test "the signature is the lower-case hex HMAC-SHA256 of the body with the secret" do
      {:ok, %{body: body, headers: [{_, sig}]}} = Simulated.pay(create!().reference)
      secret = Application.fetch_env!(:chebit, Simulated)[:webhook_secret]
      expected = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)
      assert sig == expected
    end

    test "two webhooks for the same payment have different event ids" do
      reference = create!().reference
      {:ok, first} = Simulated.webhook_for(reference)
      {:ok, second} = Simulated.webhook_for(reference)

      assert event(first)["id"] != event(second)["id"]
      assert event(first)["reference"] == event(second)["reference"]
    end

    test "webhook_for/1 does not change the payment" do
      payment = create!()
      {:ok, _} = Simulated.webhook_for(payment.reference)
      assert Simulated.fetch_payment(payment.reference) == {:ok, payment}
    end

    test "each control returns a fresh event id" do
      reference = create!().reference
      {:ok, paid} = Simulated.pay(reference, :delayed)
      {:ok, disputed} = Simulated.dispute(reference)
      {:ok, refunded} = Simulated.refund(reference)
      {:ok, again} = Simulated.webhook_for(reference)

      ids = Enum.map([paid, disputed, refunded, again], &event(&1)["id"])
      assert length(Enum.uniq(ids)) == 4
    end
  end

  describe "verify_webhook/2" do
    setup do
      reference = create!().reference
      {:ok, delivery} = Simulated.webhook_for(reference)
      %{reference: reference, delivery: delivery}
    end

    test "accepts a signed webhook", %{reference: reference, delivery: delivery} do
      assert {:ok, %{event_id: event_id, reference: ^reference}} =
               Simulated.verify_webhook(delivery.body, delivery.headers)

      assert event_id == event(delivery)["id"]
    end

    test "round trip for a webhook from a control" do
      reference = create!().reference
      {:ok, delivery} = Simulated.pay(reference)

      assert {:ok, %{reference: ^reference}} =
               Simulated.verify_webhook(delivery.body, delivery.headers)
    end

    test "accepts the header among other headers", %{delivery: delivery} do
      headers = [{"content-type", "application/json"} | delivery.headers] ++ [{"x-other", "1"}]
      assert {:ok, _} = Simulated.verify_webhook(delivery.body, headers)
    end

    test "refuses a tampered body", %{delivery: delivery} do
      body = String.replace(delivery.body, "payment.updated", "payment.updatee")
      refute body == delivery.body
      assert Simulated.verify_webhook(body, delivery.headers) == {:error, :invalid_signature}
    end

    test "refuses a tampered signature", %{delivery: delivery} do
      [{name, sig}] = delivery.headers
      last = if String.ends_with?(sig, "0"), do: "1", else: "0"
      bad = binary_part(sig, 0, byte_size(sig) - 1) <> last

      assert Simulated.verify_webhook(delivery.body, [{name, bad}]) ==
               {:error, :invalid_signature}

      assert Simulated.verify_webhook(delivery.body, [{name, String.upcase(sig)}]) ==
               {:error, :invalid_signature}

      assert Simulated.verify_webhook(delivery.body, [{name, ""}]) == {:error, :invalid_signature}
    end

    test "refuses a missing header", %{delivery: delivery} do
      assert Simulated.verify_webhook(delivery.body, []) == {:error, :invalid_signature}

      assert Simulated.verify_webhook(delivery.body, [{"content-type", "application/json"}]) ==
               {:error, :invalid_signature}
    end

    test "refuses a signature made with another secret", %{delivery: delivery} do
      sig = :hmac |> :crypto.mac(:sha256, "other", delivery.body) |> Base.encode16(case: :lower)

      assert Simulated.verify_webhook(delivery.body, [{"x-simulated-signature", sig}]) ==
               {:error, :invalid_signature}
    end

    test "a signed body that is not the expected JSON is :malformed" do
      secret = Application.fetch_env!(:chebit, Simulated)[:webhook_secret]

      for body <- [
            "not json",
            "[]",
            "null",
            "{}",
            ~s({"id": 1, "reference": "r"}),
            ~s({"id": "evt_1"}),
            ~s({"reference": "r"}),
            <<0xFF, 0xFE, 0x00>>
          ] do
        sig = :hmac |> :crypto.mac(:sha256, secret, body) |> Base.encode16(case: :lower)

        assert Simulated.verify_webhook(body, [{"x-simulated-signature", sig}]) ==
                 {:error, :malformed}
      end
    end

    test "never raises on garbage input", %{delivery: delivery} do
      bodies = [delivery.body, "", <<0xFF, 0xFE>>, nil, 42, :atom, %{}, [], {:a}]

      headers = [
        delivery.headers,
        [],
        nil,
        :headers,
        "x-simulated-signature",
        %{"x-simulated-signature" => "abc"},
        [nil],
        [:a, 1, "x"],
        [{"x-simulated-signature", nil}],
        [{"x-simulated-signature", 123}],
        [{"x-simulated-signature", <<0xFF>>}],
        [{:"x-simulated-signature", "abc"}],
        [{"x-simulated-signature"}],
        [{"a", "b", "c"}],
        [{"x-simulated-signature", "abc"} | :improper]
      ]

      for body <- bodies, hs <- headers, not (body == delivery.body and hs == delivery.headers) do
        assert {:error, reason} = Simulated.verify_webhook(body, hs)
        assert reason in [:invalid_signature, :malformed]
      end
    end

    test "never raises on random binaries" do
      check all(body <- binary(), sig <- binary(), max_runs: 100) do
        assert {:error, _} = Simulated.verify_webhook(body, [{"x-simulated-signature", sig}])
      end
    end
  end

  describe "invariant 5: exactly once in effect" do
    property "created_count is at most 1, and 1 after an ok or an unavailable_after" do
      fault = member_of([:decline, :unavailable_before, :unavailable_after])
      step = one_of([tuple({constant(:fault), fault}), constant(:create)])

      check all(steps <- list_of(step, max_length: 12), max_runs: 100) do
        reference = Ecto.UUID.generate()

        {_, must_exist?} =
          Enum.reduce(steps, {nil, false}, fn
            {:fault, kind}, {_, exists?} ->
              :ok = Simulated.fault_next_create(reference, kind)
              {kind, exists?}

            :create, {pending, exists?} ->
              result = Simulated.create_payment(request(reference))

              lost_reply? =
                pending == :unavailable_after and match?({:error, :unavailable}, result)

              {nil, exists? or lost_reply? or match?({:ok, _}, result)}
          end)

        count = Simulated.created_count(reference)
        assert count <= 1
        if must_exist?, do: assert(count == 1)
        assert Simulated.created_count(reference) == count
      end
    end

    property "a lost reply never creates a second payment" do
      check all(retries <- integer(1..6), max_runs: 50) do
        reference = Ecto.UUID.generate()
        :ok = Simulated.fault_next_create(reference, :unavailable_after)
        assert {:error, :unavailable} = Simulated.create_payment(request(reference))
        assert Simulated.created_count(reference) == 1

        ids =
          for _ <- 1..retries do
            {:ok, payment} = Simulated.create_payment(request(reference))
            payment.external_id
          end

        assert length(Enum.uniq(ids)) == 1
        assert Simulated.created_count(reference) == 1
      end
    end
  end
end
