defmodule Chebit.Webhooks do
  @moduledoc """
  The webhook inbox.

  `ingest/3` runs in the HTTP request. It checks the signature, stores the body as it
  arrived, and returns fast. `(provider, event_id)` is unique, so an event that a provider
  sends twice is stored once and processed once.

  `process/1` runs later in `Chebit.Webhooks.ProcessWorker`. It treats the event as a signal
  and calls `Chebit.Payments.sync_attempt/1`, which reads the current state from the
  provider. Events that arrive late or out of order therefore do no harm.
  """
  import Ecto.Query

  alias Chebit.Payments
  alias Chebit.Providers
  alias Chebit.Repo
  alias Chebit.Webhooks.ProcessWorker
  alias Chebit.Webhooks.ProviderEvent

  @type process_error ::
          :event_not_found | :provider_unavailable | {:rejected, Payments.sync_error()}

  @doc """
  Stores a webhook and queues its processing. The event row and the job commit together.

  A body with a bad signature is not stored: `{:error, :invalid_signature}`.
  """
  @spec ingest(term(), binary(), [{String.t(), String.t()}]) ::
          {:ok, :accepted | :duplicate}
          | {:error, :unknown_provider | :invalid_signature | :malformed}
  def ingest(provider_name, raw_body, headers) do
    with {:ok, provider} <- Providers.fetch(provider_name),
         {:ok, %{event_id: event_id, reference: reference}} <-
           provider.verify_webhook(raw_body, headers) do
      row = %{
        provider: provider_name,
        event_id: event_id,
        reference: reference,
        raw_body: raw_body,
        status: :received,
        inserted_at: DateTime.utc_now()
      }

      Repo.transact(fn -> store(row) end)
    end
  end

  defp store(row) do
    case Repo.insert_all(ProviderEvent, [row],
           on_conflict: :nothing,
           conflict_target: [:provider, :event_id],
           returning: [:id]
         ) do
      {1, [%{id: id}]} ->
        Oban.insert!(ProcessWorker.new(%{provider_event_id: id}))
        {:ok, :accepted}

      {0, _rows} ->
        {:ok, :duplicate}
    end
  end

  @doc """
  Processes one stored event.

  - `:ok`: the payment is in sync with the provider, and the event is `processed`.
    An event that is already `processed` or `failed` gives `:ok` and changes nothing.
  - `{:error, :provider_unavailable}`: try again later. The event stays `received`.
  - `{:error, {:rejected, reason}}`: the event can never apply, for example it names an
    attempt that does not exist. The event is `failed`, with the reason in `error`.
  """
  @spec process(term()) :: :ok | {:error, process_error()}
  def process(provider_event_id) when is_integer(provider_event_id) do
    case Repo.get(ProviderEvent, provider_event_id) do
      nil -> {:error, :event_not_found}
      %ProviderEvent{status: :received} = event -> sync(event)
      %ProviderEvent{} -> :ok
    end
  end

  def process(_provider_event_id), do: {:error, :event_not_found}

  defp sync(event) do
    case Payments.sync_attempt(event.reference) do
      {:ok, _intent} ->
        finish(event, :processed, nil)
        :ok

      {:error, :provider_unavailable} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        finish(event, :failed, Atom.to_string(reason))
        {:error, {:rejected, reason}}
    end
  end

  defp finish(event, status, error) do
    Repo.update_all(
      from(e in ProviderEvent, where: e.id == ^event.id and e.status == :received),
      set: [status: status, error: error, processed_at: DateTime.utc_now()]
    )
  end
end
