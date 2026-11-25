defmodule Chebit.Outbox.Sink do
  @moduledoc """
  Where the outbox publishes an event. The config key `:outbox_sink` names the module.

  `publish/1` can run more than once for one event. It returns `:ok` only when the event is
  safely handed over.
  """

  @callback publish(Chebit.Outbox.Event.t()) :: :ok | {:error, term()}
end
