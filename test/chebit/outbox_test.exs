defmodule Chebit.OutboxTest do
  use Chebit.DataCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  alias Chebit.Outbox
  alias Chebit.Outbox.Event
  alias Chebit.Outbox.PublishWorker

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        type: "payment.succeeded",
        aggregate_type: "payment_intent",
        aggregate_id: "pi_#{System.unique_integer([:positive])}",
        payload: %{"amount_minor" => 100}
      },
      extra
    )
  end

  describe "emit/1" do
    test "outside a transaction it refuses and writes nothing" do
      before = Repo.aggregate(Event, :count)
      assert {:error, :not_in_transaction} = Outbox.emit(attrs())
      assert Repo.aggregate(Event, :count) == before
      refute_enqueued(worker: PublishWorker)
    end

    test "a rolled back transaction leaves no event and no job" do
      assert {:error, :boom} =
               Repo.transact(fn ->
                 {:ok, event} = Outbox.emit(attrs())
                 send(self(), {:event_id, event.id})
                 {:error, :boom}
               end)

      assert_received {:event_id, id}
      refute Repo.get(Event, id)
      refute_enqueued(worker: PublishWorker, args: %{event_id: id})
    end

    test "a committed transaction keeps one event and one job" do
      assert {:ok, event} = Repo.transact(fn -> Outbox.emit(attrs()) end)

      assert Repo.get(Event, event.id)

      assert [_one] =
               Enum.filter(
                 all_enqueued(worker: PublishWorker),
                 &(&1.args["event_id"] == event.id)
               )

      assert_enqueued(worker: PublishWorker, args: %{event_id: event.id})
      assert event.id in Enum.map(Outbox.pending(), & &1.id)
    end
  end

  describe "emit/1 rejected input" do
    test "returns :invalid_event and writes nothing" do
      bad = [
        attrs(%{type: ""}),
        attrs(%{type: nil}),
        attrs(%{aggregate_type: 5}),
        attrs(%{aggregate_id: ""}),
        attrs(%{payload: "text"}),
        attrs(%{payload: nil}),
        %{type: "x"}
      ]

      before = Repo.aggregate(Event, :count)

      for b <- bad do
        assert {:error, :invalid_event} =
                 Repo.transact(fn -> {:ok, Outbox.emit(b)} end) |> elem(1)
      end

      assert Repo.aggregate(Event, :count) == before
    end
  end

  describe "pending/0" do
    test "lists unpublished events oldest first and skips published ones" do
      {:ok, a} = Repo.transact(fn -> Outbox.emit(attrs()) end)
      {:ok, b} = Repo.transact(fn -> Outbox.emit(attrs()) end)
      ids = [a.id, b.id]

      assert ids == Outbox.pending() |> Enum.map(& &1.id) |> Enum.filter(&(&1 in ids))

      Repo.update_all(from(e in Event, where: e.id == ^a.id),
        set: [published_at: DateTime.utc_now()]
      )

      assert [b.id] == Outbox.pending() |> Enum.map(& &1.id) |> Enum.filter(&(&1 in ids))
    end
  end
end
