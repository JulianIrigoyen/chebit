defmodule Chebit.Idempotency.Key do
  @moduledoc """
  One idempotency key of one merchant, with the response of the first request.

  `request_hash` is the SHA-256 of the method, the path and the body of the first request.
  `locked_at` is when a request last took the key. A `processing` key with an old
  `locked_at` belongs to a request that died.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "idempotency_keys" do
    field :key, :string
    field :request_hash, :binary
    field :status, Ecto.Enum, values: [:processing, :completed], default: :processing
    field :response_status, :integer
    field :response_body, :map
    field :locked_at, :utc_datetime_usec

    belongs_to :merchant, Chebit.Merchants.Merchant

    timestamps()
  end
end
