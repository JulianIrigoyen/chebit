defmodule Chebit.Webhooks.ProviderEvent do
  @moduledoc """
  One webhook from a provider, stored as it arrived.

  `(provider, event_id)` is unique: a provider that sends an event twice makes one row.
  `raw_body` is the exact request body. `reference` is the id of our payment attempt, read
  from the body after the signature check.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @timestamps_opts [type: :utc_datetime_usec]

  schema "provider_events" do
    field :provider, :string
    field :event_id, :string
    field :reference, :string
    field :raw_body, :string
    field :status, Ecto.Enum, values: [:received, :processed, :failed], default: :received
    field :error, :string
    field :processed_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
