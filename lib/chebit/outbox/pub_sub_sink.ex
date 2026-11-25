defmodule Chebit.Outbox.PubSubSink do
  @moduledoc """
  Publishes each event on `Chebit.PubSub`.

  Topics: `"events"` for each event, and `"events:<aggregate_type>:<aggregate_id>"` for the
  events of one aggregate. The message is `{:chebit_event, %Chebit.Outbox.Event{}}`.
  """
  @behaviour Chebit.Outbox.Sink

  @impl Chebit.Outbox.Sink
  def publish(event) do
    message = {:chebit_event, event}
    aggregate_topic = "events:#{event.aggregate_type}:#{event.aggregate_id}"

    with :ok <- Phoenix.PubSub.broadcast(Chebit.PubSub, "events", message) do
      Phoenix.PubSub.broadcast(Chebit.PubSub, aggregate_topic, message)
    end
  end
end
