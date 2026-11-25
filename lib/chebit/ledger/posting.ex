defmodule Chebit.Ledger.Posting do
  @moduledoc """
  One debit or one credit on one account. `amount_minor` is always positive.

  The row is append-only: a trigger refuses UPDATE and DELETE.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "postings" do
    field :currency, Ecto.Enum, values: Chebit.Money.currencies()
    field :direction, Ecto.Enum, values: [:debit, :credit]
    field :amount_minor, :integer

    belongs_to :transaction, Chebit.Ledger.Transaction
    belongs_to :account, Chebit.Ledger.Account

    timestamps(updated_at: false)
  end
end
