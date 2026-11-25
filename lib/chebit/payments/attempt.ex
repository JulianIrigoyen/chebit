defmodule Chebit.Payments.Attempt do
  @moduledoc """
  One try to collect an intent through one provider.

  The attempt id is the `reference` that the provider receives. It is also the provider's
  idempotency key, so a repeated send creates one payment at the provider.

  - `initiated`: the row exists. The provider did not confirm the payment yet.
  - `dispatched`: the provider confirmed the payment and gave `external_id`.
  - `failed`: the provider refused to create the payment. The intent can get a new attempt.

  `provider_status` is the last status that the provider reported.
  `payment_data` is what the payer needs, for example a QR string or a Lightning invoice.
  """
  use Chebit.Schema

  @type t :: %__MODULE__{}

  schema "payment_attempts" do
    field :provider, :string
    field :status, Ecto.Enum, values: [:initiated, :dispatched, :failed], default: :initiated
    field :external_id, :string
    field :provider_status, :string
    field :payment_data, :map, default: %{}
    field :failure_reason, :string

    belongs_to :payment_intent, Chebit.Payments.Intent

    timestamps()
  end
end
