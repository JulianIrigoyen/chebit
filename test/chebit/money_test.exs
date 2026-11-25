defmodule Chebit.MoneyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chebit.Money

  doctest Chebit.Money

  @max 9_223_372_036_854_775_807

  describe "currencies/0 and valid_currency?/1" do
    test "lists the five currencies" do
      assert Enum.sort(Money.currencies()) == [:ARS, :BTC, :USD, :USDC, :USDT]
    end

    test "accepts each listed currency" do
      for c <- Money.currencies(), do: assert(Money.valid_currency?(c))
    end

    test "refuses anything else" do
      for c <- [:EUR, :usd, "USD", "ARS", nil, 1, [], %{}, :ars] do
        refute Money.valid_currency?(c)
      end
    end
  end

  describe "exponent/1" do
    test "returns the decimal places of each currency" do
      assert Money.exponent(:ARS) == 2
      assert Money.exponent(:USD) == 2
      assert Money.exponent(:BTC) == 8
      assert Money.exponent(:USDT) == 6
      assert Money.exponent(:USDC) == 6
    end
  end

  describe "max_amount_minor/0" do
    test "is the bigint maximum" do
      assert Money.max_amount_minor() == @max
      assert Money.max_amount_minor() == Bitwise.bsl(1, 63) - 1
    end
  end

  describe "valid_amount?/1" do
    test "accepts positive integers up to the bigint maximum" do
      for a <- [1, 2, 100, 1_000_000, @max - 1, @max], do: assert(Money.valid_amount?(a))
    end

    test "rejects zero and negatives" do
      for a <- [0, -1, -100, -@max], do: refute(Money.valid_amount?(a))
    end

    test "rejects a value above bigint (invariant 7)" do
      for a <- [@max + 1, @max * 2, 10 ** 30], do: refute(Money.valid_amount?(a))
    end

    test "rejects floats" do
      for a <- [1.0, 0.5, 100.0, 1.0e10, -1.0, 0.0], do: refute(Money.valid_amount?(a))
    end

    test "rejects strings and other terms" do
      for a <- ["1", "100", "", "abc", nil, :one, [1], %{}, {1}, Decimal.new(1), true] do
        refute Money.valid_amount?(a)
      end
    end

    property "accepts exactly the integers in 1..max" do
      check all(a <- integer(-1000..1000), max_runs: 100) do
        assert Money.valid_amount?(a) == a >= 1
      end

      check all(a <- float(min: -1.0e6, max: 1.0e6), max_runs: 50) do
        refute Money.valid_amount?(a)
      end
    end
  end

  describe "fee_minor/2" do
    test "rounds down" do
      assert Money.fee_minor(10_000, 250) == 250
      assert Money.fee_minor(999, 250) == 24
      assert Money.fee_minor(1, 9_999) == 0
      assert Money.fee_minor(3, 5_000) == 1
    end

    test "handles the largest amount without overflow" do
      assert Money.fee_minor(@max, 10_000) == @max
      assert Money.fee_minor(@max, 0) == 0
    end

    property "is an integer with 0 <= fee <= amount" do
      check all(amount <- integer(1..@max), bps <- integer(0..10_000), max_runs: 200) do
        fee = Money.fee_minor(amount, bps)
        assert is_integer(fee)
        assert fee >= 0
        assert fee <= amount
      end
    end

    property "is monotonic in fee_bps" do
      check all(
              amount <- integer(1..1_000_000_000),
              a <- integer(0..10_000),
              b <- integer(0..10_000),
              max_runs: 200
            ) do
        {low, high} = {min(a, b), max(a, b)}
        assert Money.fee_minor(amount, low) <= Money.fee_minor(amount, high)
      end
    end

    property "is monotonic in the amount" do
      check all(
              a <- integer(1..1_000_000_000),
              b <- integer(1..1_000_000_000),
              bps <- integer(0..10_000),
              max_runs: 200
            ) do
        {low, high} = {min(a, b), max(a, b)}
        assert Money.fee_minor(low, bps) <= Money.fee_minor(high, bps)
      end
    end

    property "0 bps is 0 and 10_000 bps is the amount" do
      check all(amount <- integer(1..@max), max_runs: 100) do
        assert Money.fee_minor(amount, 0) == 0
        assert Money.fee_minor(amount, 10_000) == amount
      end
    end
  end
end
