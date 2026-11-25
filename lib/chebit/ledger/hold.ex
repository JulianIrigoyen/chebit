defmodule Chebit.Ledger.Hold do
  @moduledoc """
  A reserve on part of an account balance.

  An active hold lowers the available balance and moves no money. A hold ends one way:

  - `captured`: the held amount left the account in the transaction `capture_transaction_id`.
  - `released`: the amount is available again.

  `(source_type, source_id)` is unique: one operation places one hold.
  """
  use Chebit.Schema

  @type t :: %__MODULE__{}

  schema "holds" do
    field :amount_minor, :integer
    field :status, Ecto.Enum, values: [:active, :captured, :released], default: :active
    field :source_type, :string
    field :source_id, :string

    belongs_to :account, Chebit.Ledger.Account
    belongs_to :capture_transaction, Chebit.Ledger.Transaction

    timestamps()
  end
end
