defmodule Chebit.Schema do
  @moduledoc """
  Defaults for each Ecto schema: UUID keys and microsecond UTC timestamps.

  A table that is an ordered log (`postings`, `outbox_events`, `provider_events`,
  `idempotency_keys`) overrides the key with a `bigserial`, because its order matters.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
