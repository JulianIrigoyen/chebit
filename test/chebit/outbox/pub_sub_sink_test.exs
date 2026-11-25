defmodule Chebit.Outbox.PubSubSinkTest do
  use ExUnit.Case, async: true

  alias Chebit.Outbox.Event
  alias Chebit.Outbox.PubSubSink

  describe "publish/1" do
    test "broadcasts on the global and the aggregate topic" do
      id = System.unique_integer([:positive])

      event = %Event{
        id: id,
        type: "t",
        aggregate_type: "payment_intent",
        aggregate_id: "pi_#{id}",
        payload: %{}
      }

      :ok = Phoenix.PubSub.subscribe(Chebit.PubSub, "events")
      :ok = Phoenix.PubSub.subscribe(Chebit.PubSub, "events:payment_intent:pi_#{id}")

      assert :ok = PubSubSink.publish(event)
      assert_receive {:chebit_event, ^event}
      assert_receive {:chebit_event, ^event}
      refute_receive {:chebit_event, _}, 50
    end
  end
end
