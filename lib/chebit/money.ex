defmodule Chebit.Money do
  @moduledoc """
  Currencies and amounts.

  An amount is an integer count of the smallest unit of its currency: centavos for ARS,
  cents for USD, satoshis for BTC, and 10^-6 units for USDT and USDC. A field or variable
  that holds an amount ends in `_minor`. No float and no Decimal holds money.
  """

  @exponents %{ARS: 2, USD: 2, BTC: 8, USDT: 6, USDC: 6}
  @currencies Map.keys(@exponents)

  # Postgres `bigint` upper bound. An amount above it cannot be stored.
  @max_amount_minor 9_223_372_036_854_775_807

  @type currency :: :ARS | :USD | :BTC | :USDT | :USDC
  @type amount_minor :: pos_integer()

  @doc "Lists the currencies that the ledger accepts."
  @spec currencies() :: [currency()]
  def currencies, do: @currencies

  @doc "Returns the number of decimal places between the main unit and the smallest unit."
  @spec exponent(currency()) :: non_neg_integer()
  def exponent(currency) when is_map_key(@exponents, currency),
    do: Map.fetch!(@exponents, currency)

  @doc "Returns the largest amount that a `bigint` column can store."
  @spec max_amount_minor() :: pos_integer()
  def max_amount_minor, do: @max_amount_minor

  @doc "Returns true for a positive integer that fits in a `bigint` column."
  @spec valid_amount?(term()) :: boolean()
  def valid_amount?(amount), do: is_integer(amount) and amount > 0 and amount <= @max_amount_minor

  @doc "Returns true for a currency that the ledger accepts."
  @spec valid_currency?(term()) :: boolean()
  def valid_currency?(currency), do: currency in @currencies

  @doc """
  Computes a fee in basis points. The result rounds down, in favour of the payer of the fee.

      iex> Chebit.Money.fee_minor(10_000, 250)
      250
      iex> Chebit.Money.fee_minor(999, 250)
      24
  """
  @spec fee_minor(amount_minor(), 0..10_000) :: non_neg_integer()
  def fee_minor(amount_minor, fee_bps)
      when is_integer(amount_minor) and amount_minor > 0 and fee_bps in 0..10_000 do
    div(amount_minor * fee_bps, 10_000)
  end
end
