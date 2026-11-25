defmodule Chebit.Outbox.PublishWorker do
  @moduledoc """
  Publishes one outbox event. Args: `%{"event_id" => id}`.

  - An event that already has `published_at` is skipped: the job is safe to run twice.
  - A sink error fails the job, and Oban runs it again with backoff.
  - An event id that does not exist discards the job.
  """
  use Oban.Worker, queue: :outbox, max_attempts: 20

  import Ecto.Query, only: [from: 2]

  alias Chebit.Outbox.Event
  alias Chebit.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}}) when is_integer(id) do
    case Repo.get(Event, id) do
      nil -> {:cancel, :event_not_found}
      %Event{published_at: %DateTime{}} -> :ok
      %Event{} = event -> publish(event)
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp publish(event) do
    sink = Application.fetch_env!(:chebit, :outbox_sink)

    with :ok <- sink.publish(event) do
      # The stamp is conditional: a concurrent run that stamped first keeps its time.
      Repo.update_all(
        from(e in Event, where: e.id == ^event.id and is_nil(e.published_at)),
        set: [published_at: DateTime.utc_now()]
      )

      :ok
    end
  end
end
