defmodule Chebit.Outbox do
  @moduledoc """
  The transactional outbox.

  A change and its event commit together, or neither does. `emit/1` writes the event row and
  one Oban job in the transaction of the caller. After the commit,
  `Chebit.Outbox.PublishWorker` hands the event to the sink and stamps `published_at`.

  Delivery is at least once: a crash after the sink call and before the stamp publishes the
  event again. A consumer drops a duplicate by `event.id`. A retry can deliver an event
  after a later one; a consumer orders them by `event.id`.
  """

  import Ecto.Query, only: [from: 2]

  alias Chebit.Outbox.Event
  alias Chebit.Outbox.PublishWorker
  alias Chebit.Repo

  @type attrs :: %{
          type: String.t(),
          aggregate_type: String.t(),
          aggregate_id: String.t(),
          payload: map()
        }

  @doc """
  Writes an event and the job that publishes it.

  The caller must be inside a database transaction. Outside one, the event could commit
  without the change that it describes, so the call is refused with
  `{:error, :not_in_transaction}` and writes nothing.
  """
  @spec emit(attrs()) :: {:ok, Event.t()} | {:error, :not_in_transaction | :invalid_event}
  def emit(attrs) do
    cond do
      not Repo.in_transaction?() -> {:error, :not_in_transaction}
      not valid?(attrs) -> {:error, :invalid_event}
      true -> {:ok, insert!(attrs)}
    end
  end

  @doc "Lists the events that no worker published yet, oldest first."
  @spec pending() :: [Event.t()]
  def pending do
    Repo.all(from(e in Event, where: is_nil(e.published_at), order_by: [asc: e.id]))
  end

  @doc "Counts the events that no worker published yet: the outbox backlog."
  @spec count_pending() :: non_neg_integer()
  def count_pending do
    Repo.aggregate(from(e in Event, where: is_nil(e.published_at)), :count)
  end

  @doc "Lists the newest events, newest first. `limit` caps the rows."
  @spec recent(pos_integer()) :: [Event.t()]
  def recent(limit) when is_integer(limit) and limit > 0 do
    Repo.all(from(e in Event, order_by: [desc: e.id], limit: ^limit))
  end

  defp valid?(%{type: t, aggregate_type: at, aggregate_id: ai, payload: p}) do
    Enum.all?([t, at, ai], &(is_binary(&1) and &1 != "")) and is_map(p) and not is_struct(p)
  end

  defp valid?(_attrs), do: false

  # A database failure here raises, and the transaction of the caller rolls back.
  defp insert!(attrs) do
    event =
      Repo.insert!(%Event{
        type: attrs.type,
        aggregate_type: attrs.aggregate_type,
        aggregate_id: attrs.aggregate_id,
        payload: attrs.payload
      })

    %{event_id: event.id} |> PublishWorker.new() |> Oban.insert!()
    event
  end
end
