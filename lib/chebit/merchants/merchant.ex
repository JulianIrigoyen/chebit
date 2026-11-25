defmodule Chebit.Merchants.Merchant do
  @moduledoc """
  A business that takes payments.

  `api_key_hash` is the SHA-256 of the API key. The key itself is never stored.
  `fee_bps` is the fee that Chebit keeps from each payment, in basis points.
  """
  use Chebit.Schema

  @type t :: %__MODULE__{}

  schema "merchants" do
    field :name, :string
    field :api_key_hash, :binary, redact: true
    field :fee_bps, :integer, default: 0

    timestamps()
  end
end
