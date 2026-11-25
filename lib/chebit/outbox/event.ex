defmodule Chebit.Outbox.Event do
  @moduledoc """
  One domain event that waits for publication, or that was published.

  The row commits in the same database transaction as the change that it describes.
  `id` grows with time. A consumer uses it to drop a duplicate and to order events.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @timestamps_opts [type: :utc_datetime_usec]

  schema "outbox_events" do
    field :type, :string
    field :aggregate_type, :string
    field :aggregate_id, :string
    field :payload, :map
    field :published_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end
end
