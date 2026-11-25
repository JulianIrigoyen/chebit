defmodule Chebit.Ledger.Transaction do
  @moduledoc """
  A group of postings that sums to zero for each currency.

  `(source_type, source_id, kind)` is unique: one operation writes one transaction, even
  when a caller repeats it. `reverses_id` points at the transaction that this one corrects.
  The row is append-only: a trigger refuses UPDATE and DELETE.
  """
  use Chebit.Schema

  @type t :: %__MODULE__{}

  schema "ledger_transactions" do
    field :kind, :string
    field :source_type, :string
    field :source_id, :string
    field :metadata, :map, default: %{}

    belongs_to :reverses, __MODULE__
    has_many :postings, Chebit.Ledger.Posting

    timestamps(updated_at: false)
  end
end
