defmodule Chebit.Payments.Intent do
  @moduledoc """
  A payment from the point of view of the merchant: who gets how much, and its status.

  The server creates the intent and returns its id. The client confirms that id. A retry
  uses the same intent. `Chebit.Payments.StateMachine` defines the status values.
  `failure_reason` holds a short code such as `"provider_declined"`.
  """
  use Chebit.Schema

  alias Chebit.Payments.StateMachine

  @type t :: %__MODULE__{}

  schema "payment_intents" do
    field :amount_minor, :integer
    field :currency, Ecto.Enum, values: Chebit.Money.currencies()
    field :status, Ecto.Enum, values: StateMachine.statuses(), default: :created
    field :failure_reason, :string
    field :description, :string
    field :metadata, :map, default: %{}
    field :idempotency_key, :string
    field :expires_at, :utc_datetime_usec

    belongs_to :merchant, Chebit.Merchants.Merchant
    has_many :attempts, Chebit.Payments.Attempt, foreign_key: :payment_intent_id

    timestamps()
  end
end
