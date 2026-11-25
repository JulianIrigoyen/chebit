defmodule Chebit.Webhooks.ProcessWorker do
  @moduledoc """
  Processes one stored webhook. Args: `%{"provider_event_id" => id}`.

  Each event runs in its own supervised process. A crash or a provider outage fails only
  this job, and Oban runs it again with backoff. An event that can never apply is cancelled.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 10

  alias Chebit.Webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_event_id" => id}}) do
    case Webhooks.process(id) do
      :ok -> :ok
      {:error, :provider_unavailable} -> {:error, :provider_unavailable}
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}
end
