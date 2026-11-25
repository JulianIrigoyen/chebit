defmodule Chebit.IdempotencyTest do
  use Chebit.DataCase, async: true
  use ExUnitProperties

  alias Chebit.Fixtures
  alias Chebit.Idempotency
  alias Chebit.Idempotency.Key

  setup do
    %{merchant: merchant} = Fixtures.merchant_fixture()
    %{merchant_id: merchant.id, hash: Idempotency.request_hash("POST", "/v1/x", %{"a" => 1})}
  end

  defp counted(counter, response) do
    fn ->
      Agent.update(counter, &(&1 + 1))
      response
    end
  end

  defp calls(counter), do: Agent.get(counter, & &1)

  defp new_counter, do: start_supervised!({Agent, fn -> 0 end}, id: make_ref())

  describe "run/5" do
    test "first call runs fun and replays the stored response", ctx do
      counter = new_counter()
      fun = counted(counter, {201, %{id: "pi_1", n: 5}})

      assert {:ok, %{status: 201, body: %{"id" => "pi_1", "n" => 5}, replayed?: false}} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun)

      assert {:ok, %{status: 201, body: %{"id" => "pi_1", "n" => 5}, replayed?: true}} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun)

      assert calls(counter) == 1
    end

    test "a different hash with the same key gives :key_reused", ctx do
      counter = new_counter()
      fun = counted(counter, {200, %{}})
      {:ok, _} = Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun)
      other = Idempotency.request_hash("POST", "/v1/x", %{"a" => 2})

      assert {:error, :key_reused} = Idempotency.run(ctx.merchant_id, "k1", other, fun)
      assert calls(counter) == 1
    end

    test "a call from inside fun with the same key gives :in_progress", ctx do
      result =
        Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fn ->
          inner = Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fn -> {200, %{}} end)
          {200, %{inner: inspect(inner)}}
        end)

      assert {:ok, %{body: %{"inner" => inner}}} = result
      assert inner == inspect({:error, :in_progress})
    end

    test "the same key for two merchants is independent", ctx do
      %{merchant: other} = Fixtures.merchant_fixture()
      counter = new_counter()
      fun = counted(counter, {200, %{}})

      assert {:ok, %{replayed?: false}} = Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun)
      assert {:ok, %{replayed?: false}} = Idempotency.run(other.id, "k1", ctx.hash, fun)
      assert calls(counter) == 2
    end

    test "a raise propagates, deletes the key row and lets the next call run", ctx do
      assert_raise RuntimeError, "boom", fn ->
        Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fn -> raise "boom" end)
      end

      refute Repo.get_by(Key, merchant_id: ctx.merchant_id, key: "k1")

      assert {:ok, %{status: 200, replayed?: false}} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fn -> {200, %{}} end)
    end

    test "a response with status 500 or above is returned and not stored", ctx do
      counter = new_counter()

      assert {:ok, %{status: 503, body: %{"error" => "down"}, replayed?: false}} =
               Idempotency.run(
                 ctx.merchant_id,
                 "k1",
                 ctx.hash,
                 counted(counter, {503, %{error: "down"}})
               )

      refute Repo.get_by(Key, merchant_id: ctx.merchant_id, key: "k1")

      assert {:ok, %{status: 202, replayed?: false}} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, counted(counter, {202, %{}}))

      assert {:ok, %{status: 202, replayed?: true}} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, counted(counter, {500, %{}}))

      assert calls(counter) == 2
    end

    test "a stale processing row is taken over, a fresh one is not", ctx do
      now = DateTime.utc_now()
      timeout = Idempotency.lock_timeout_ms()
      :ok = insert_processing(ctx, "k1", now)
      fun = fn -> {200, %{ok: true}} end

      assert {:error, :in_progress} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun, now: now)

      almost = DateTime.add(now, timeout - 1_000, :millisecond)

      assert {:error, :in_progress} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun, now: almost)

      later = DateTime.add(now, timeout + 1_000, :millisecond)

      assert {:ok, %{status: 200, replayed?: false}} =
               Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun, now: later)

      assert {:ok, %{replayed?: true}} = Idempotency.run(ctx.merchant_id, "k1", ctx.hash, fun)
    end

    test "a stale row with another hash is not taken over", ctx do
      now = DateTime.utc_now()
      :ok = insert_processing(ctx, "k1", now)
      other = Idempotency.request_hash("POST", "/v1/x", %{"a" => 2})
      later = DateTime.add(now, Idempotency.lock_timeout_ms() + 1_000, :millisecond)

      assert {:error, :key_reused} =
               Idempotency.run(ctx.merchant_id, "k1", other, fn -> {200, %{}} end, now: later)
    end
  end

  describe "request_hash/3" do
    test "ignores key order and differs on method, path and body" do
      base = Idempotency.request_hash("POST", "/a", %{"x" => 1, "y" => %{"p" => 1, "q" => 2}})

      assert base ==
               Idempotency.request_hash("POST", "/a", %{"y" => %{"q" => 2, "p" => 1}, "x" => 1})

      refute base ==
               Idempotency.request_hash("PUT", "/a", %{"x" => 1, "y" => %{"p" => 1, "q" => 2}})

      refute base ==
               Idempotency.request_hash("POST", "/b", %{"x" => 1, "y" => %{"p" => 1, "q" => 2}})

      refute base ==
               Idempotency.request_hash("POST", "/a", %{"x" => 2, "y" => %{"p" => 1, "q" => 2}})
    end
  end

  describe "run/5 invariant 4" do
    property "fun runs once per key and each same-body retry gets the first response" do
      %{merchant: merchant} = Fixtures.merchant_fixture()
      counter = new_counter()

      check all calls <- list_of({integer(0..3), integer(0..1)}, min_length: 1, max_length: 20),
                max_runs: 25 do
        prefix = "p#{System.unique_integer([:positive])}"
        Agent.update(counter, fn _ -> 0 end)

        results =
          for {k, variant} <- calls do
            hash = Idempotency.request_hash("POST", "/x", %{"v" => variant})

            fun = fn ->
              Agent.update(counter, &(&1 + 1))
              {200, %{key: k, variant: variant}}
            end

            {k, variant, Idempotency.run(merchant.id, "#{prefix}-#{k}", hash, fun)}
          end

        first_by_key =
          Enum.reduce(calls, %{}, fn {k, v}, acc -> Map.put_new(acc, k, v) end)

        assert Agent.get(counter, & &1) == map_size(first_by_key)

        for {k, variant, result} <- results do
          first_variant = Map.fetch!(first_by_key, k)

          if variant == first_variant do
            assert {:ok, %{status: 200, body: %{"key" => ^k, "variant" => ^first_variant}}} =
                     result
          else
            assert result == {:error, :key_reused}
          end
        end
      end
    end
  end

  defp insert_processing(ctx, key, now) do
    {1, _} =
      Repo.insert_all(Key, [
        %{
          merchant_id: ctx.merchant_id,
          key: key,
          request_hash: ctx.hash,
          status: :processing,
          locked_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  describe "run/5 after a take-over" do
    # Each `fun` here reports that it started and then waits, so the test decides the order
    # in which two callers of one key finish.
    defp blocked(parent, tag, response) do
      fn ->
        send(parent, {:started, tag, self()})

        receive do
          :finish -> response
        end
      end
    end

    defp later(now), do: DateTime.add(now, Idempotency.lock_timeout_ms() + 1_000, :millisecond)

    test "a slow caller that fails cannot free the key of the caller that took it over", ctx do
      now = DateTime.utc_now()
      parent = self()

      slow =
        Task.async(fn ->
          Idempotency.run(ctx.merchant_id, "k", ctx.hash, blocked(parent, :slow, {503, %{}}),
            now: now
          )
        end)

      assert_receive {:started, :slow, slow_pid}, 2_000

      owner =
        Task.async(fn ->
          fun = blocked(parent, :owner, {201, %{"id" => "pi_1"}})
          Idempotency.run(ctx.merchant_id, "k", ctx.hash, fun, now: later(now))
        end)

      assert_receive {:started, :owner, owner_pid}, 2_000

      # The slow caller fails now. The row belongs to the owner, and it must stay.
      send(slow_pid, :finish)
      assert {:ok, %{status: 503, replayed?: false}} = Task.await(slow)
      assert %Key{status: :processing} = Repo.get_by(Key, merchant_id: ctx.merchant_id, key: "k")

      # So no other request can take the key while the owner still runs.
      other = Idempotency.request_hash("POST", "/v1/x", %{"a" => 2})

      assert {:error, :key_reused} =
               Idempotency.run(ctx.merchant_id, "k", other, fn -> {201, %{}} end, now: later(now))

      send(owner_pid, :finish)

      assert {:ok, %{status: 201, body: %{"id" => "pi_1"}, replayed?: false}} =
               Task.await(owner)

      assert {:ok, %{status: 201, body: %{"id" => "pi_1"}, replayed?: true}} =
               Idempotency.run(ctx.merchant_id, "k", ctx.hash, fn -> flunk("must not run") end,
                 now: later(now)
               )
    end

    test "a slow caller that succeeds late returns the answer that the new owner stored", ctx do
      now = DateTime.utc_now()
      parent = self()

      slow =
        Task.async(fn ->
          fun = blocked(parent, :slow, {201, %{"from" => "slow"}})
          Idempotency.run(ctx.merchant_id, "k", ctx.hash, fun, now: now)
        end)

      assert_receive {:started, :slow, slow_pid}, 2_000

      assert {:ok, %{status: 201, body: %{"from" => "owner"}, replayed?: false}} =
               Idempotency.run(ctx.merchant_id, "k", ctx.hash, fn -> {201, %{from: "owner"}} end,
                 now: later(now)
               )

      send(slow_pid, :finish)

      assert {:ok, %{status: 201, body: %{"from" => "owner"}, replayed?: true}} =
               Task.await(slow)

      assert %Key{status: :completed, response_body: %{"from" => "owner"}} =
               Repo.get_by(Key, merchant_id: ctx.merchant_id, key: "k")
    end
  end
end
