defmodule Chebit.Idempotency.ConcurrencyTest do
  use Chebit.UnboxedCase

  alias Chebit.Fixtures
  alias Chebit.Idempotency

  describe "run/5 with 30 concurrent callers" do
    test "fun runs once, callers get the response or :in_progress, a retry replays" do
      %{merchant: merchant} = Fixtures.merchant_fixture()
      hash = Idempotency.request_hash("POST", "/v1/x", %{"a" => 1})
      counter = start_supervised!({Agent, fn -> 0 end})

      fun = fn ->
        Agent.update(counter, &(&1 + 1))
        Process.sleep(50)
        {201, %{id: "pi_1"}}
      end

      results =
        race(for _ <- 1..30, do: fn -> Idempotency.run(merchant.id, "race-key", hash, fun) end)

      assert Agent.get(counter, & &1) == 1

      for result <- results do
        assert match?({:ok, %{status: 201, body: %{"id" => "pi_1"}}}, result) or
                 result == {:error, :in_progress}
      end

      assert Enum.count(results, &match?({:ok, %{replayed?: false}}, &1)) == 1

      assert {:ok, %{status: 201, body: %{"id" => "pi_1"}, replayed?: true}} =
               Idempotency.run(merchant.id, "race-key", hash, fun)

      assert Agent.get(counter, & &1) == 1
    end
  end
end
