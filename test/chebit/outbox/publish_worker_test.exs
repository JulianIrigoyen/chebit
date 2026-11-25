defmodule Chebit.Outbox.PublishWorkerTest do
  use Chebit.DataCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  alias Chebit.Outbox
  alias Chebit.Outbox.Event
  alias Chebit.Outbox.PublishWorker
  alias Chebit.Outbox.TestSink

  defp emit_event do
    {:ok, event} =
      Repo.transact(fn ->
        Outbox.emit(%{
          type: "payment.succeeded",
          aggregate_type: "payment_intent",
          aggregate_id: "pi_#{System.unique_integer([:positive])}",
          payload: %{"n" => 1}
        })
      end)

    event
  end

  describe "perform/1" do
    test "publishes to the sink and stamps published_at" do
      event = emit_event()
      assert :ok = perform_job(PublishWorker, %{event_id: event.id})
      assert_receive {:outbox_published, %Event{id: id}}
      assert id == event.id
      assert %DateTime{} = Repo.get!(Event, event.id).published_at
    end

    test "a second run does not publish again and keeps the stamp" do
      event = emit_event()
      assert :ok = perform_job(PublishWorker, %{event_id: event.id})
      assert_receive {:outbox_published, _}
      stamp = Repo.get!(Event, event.id).published_at

      assert :ok = perform_job(PublishWorker, %{event_id: event.id})
      refute_receive {:outbox_published, _}, 50
      assert Repo.get!(Event, event.id).published_at == stamp
    end

    test "a sink failure errors, leaves published_at nil, and the next run publishes" do
      event = emit_event()
      TestSink.fail_next()

      assert {:error, :sink_down} = perform_job(PublishWorker, %{event_id: event.id})
      refute_receive {:outbox_published, _}, 50
      assert Repo.get!(Event, event.id).published_at == nil

      assert :ok = perform_job(PublishWorker, %{event_id: event.id})
      assert_receive {:outbox_published, %Event{id: id}}
      assert id == event.id
      assert %DateTime{} = Repo.get!(Event, event.id).published_at
    end
  end

  describe "perform/1 rejected input" do
    test "an unknown event id cancels" do
      assert {:cancel, :event_not_found} = perform_job(PublishWorker, %{event_id: 999_999_999})
    end

    test "bad args cancel" do
      assert {:cancel, :invalid_args} = perform_job(PublishWorker, %{event_id: "x"})
      assert {:cancel, :invalid_args} = perform_job(PublishWorker, %{})
    end
  end
end
