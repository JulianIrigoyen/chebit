defmodule Chebit.Ledger.Account do
  @moduledoc """
  One account for each owner, kind and currency.

  `balance_minor` is credits minus debits. It is a cache of the postings and never the
  source of truth. `held_minor` is the sum of the active holds.

  - A merchant or user account is a liability: a positive balance is money that Chebit owes.
    Its available balance (`balance_minor - held_minor`) is never negative.
  - A house account can be negative. A negative clearing balance is money that a provider
    holds for Chebit.
  """
  use Chebit.Schema

  @type t :: %__MODULE__{}

  schema "accounts" do
    field :owner_type, Ecto.Enum, values: [:house, :merchant, :user]
    field :owner_id, :binary_id
    field :kind, :string
    field :currency, Ecto.Enum, values: Chebit.Money.currencies()
    field :balance_minor, :integer, default: 0
    field :held_minor, :integer, default: 0

    timestamps(updated_at: false)
  end
end
