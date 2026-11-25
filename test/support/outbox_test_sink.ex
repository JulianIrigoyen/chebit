defmodule Chebit.Outbox.TestSink do
  @moduledoc """
  The outbox sink for tests. It sends `{:outbox_published, event}` to the test process.

  It finds the test process through `$callers`, which Oban sets when a test runs a job
  with `perform_job/3` or `Oban.drain_queue/2`. Call `fail_next/0` to make the next
  `publish/1` in this test process return an error.
  """
  @behaviour Chebit.Outbox.Sink

  @impl Chebit.Outbox.Sink
  def publish(event) do
    owner = owner()

    case Process.get({__MODULE__, :fail_next}) do
      true ->
        Process.delete({__MODULE__, :fail_next})
        {:error, :sink_down}

      _other ->
        send(owner, {:outbox_published, event})
        :ok
    end
  end

  @doc "Makes the next `publish/1` that runs in the calling process fail."
  @spec fail_next() :: :ok
  def fail_next do
    Process.put({__MODULE__, :fail_next}, true)
    :ok
  end

  defp owner do
    case Process.get(:"$callers") do
      [caller | _rest] -> caller
      _none -> self()
    end
  end
end
